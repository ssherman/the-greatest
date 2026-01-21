require "test_helper"

module Music
  class Song
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source_song = music_songs(:time)
        @target_song = music_songs(:money)

        # Clean up any ranked_items from fixtures to ensure tests start with clean state
        RankedItem.where(item: @source_song).destroy_all
        RankedItem.where(item: @target_song).destroy_all
      end

      test "should successfully merge songs and return success result" do
        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?, "Merger failed with errors: #{result.errors.inspect}"
        assert_equal @target_song, result.data
        assert_empty result.errors
      end

      test "should reassign tracks to target song" do
        track = music_tracks(:dark_side_original_1)

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        track.reload

        assert_equal @target_song.id, track.song_id
      end

      test "should reassign identifiers to target song" do
        identifier = Identifier.create!(
          identifiable: @source_song,
          identifier_type: :music_musicbrainz_recording_id,
          value: "test-mb-id-123"
        )

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        identifier.reload

        assert_equal @target_song.id, identifier.identifiable_id
        assert_equal "Music::Song", identifier.identifiable_type
      end

      test "should handle duplicate identifiers when merging" do
        shared_id = "shared-musicbrainz-id"

        source_identifier = Identifier.create!(
          identifiable: @source_song,
          identifier_type: :music_musicbrainz_recording_id,
          value: shared_id
        )

        target_identifier = Identifier.create!(
          identifiable: @target_song,
          identifier_type: :music_musicbrainz_recording_id,
          value: shared_id
        )

        initial_target_count = @target_song.identifiers.count

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload

        assert_equal initial_target_count, @target_song.identifiers.count
        assert_not Identifier.exists?(source_identifier.id)
        assert Identifier.exists?(target_identifier.id)

        assert_equal 1, @target_song.identifiers.where(
          identifier_type: :music_musicbrainz_recording_id,
          value: shared_id
        ).count
      end

      test "should merge category_items with duplicate handling" do
        category = categories(:music_rock_genre)

        CategoryItem.create!(
          item: @source_song,
          category: category
        )

        CategoryItem.create!(
          item: @target_song,
          category: category
        )

        initial_count = @target_song.category_items.count

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload

        assert_equal initial_count, @target_song.category_items.count
      end

      test "should reassign external_links to target song" do
        external_link = ExternalLink.create!(
          parent: @source_song,
          link_category: :product_link,
          url: "https://example.com",
          name: "Buy on Example"
        )

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        external_link.reload

        assert_equal @target_song.id, external_link.parent_id
        assert_equal "Music::Song", external_link.parent_type
      end

      test "should merge list_items with duplicate handling" do
        list = lists(:music_songs_list)

        ListItem.create!(
          list: list,
          listable: @source_song,
          position: 5
        )

        ListItem.create!(
          list: list,
          listable: @target_song,
          position: 10
        )

        initial_count = @target_song.list_items.count

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload

        assert_equal initial_count, @target_song.list_items.count
      end

      test "should merge forward song_relationships" do
        related_song = music_songs(:wish_you_were_here)

        relationship = Music::SongRelationship.create!(
          song: @source_song,
          related_song: related_song,
          relation_type: :cover
        )

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?

        assert Music::SongRelationship.exists?(
          song_id: @target_song.id,
          related_song_id: related_song.id,
          relation_type: :cover
        )

        assert_not Music::SongRelationship.exists?(relationship.id)
      end

      test "should merge inverse song_relationships" do
        other_song = music_songs(:wish_you_were_here)

        relationship = Music::SongRelationship.create!(
          song: other_song,
          related_song: @source_song,
          relation_type: :remix
        )

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        relationship.reload

        assert_equal @target_song.id, relationship.related_song_id
      end

      test "should trigger target song touch to queue reindex via SearchIndexable" do
        @target_song.reload
        original_updated_at = @target_song.updated_at

        sleep 0.01

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload

        assert_operator @target_song.updated_at, :>, original_updated_at
      end

      test "should destroy source song after merge" do
        source_id = @source_song.id

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        assert_not Music::Song.exists?(source_id)
      end

      test "should destroy source ranked_items when source song is destroyed" do
        config = Music::Songs::RankingConfiguration.create!(
          name: "Test Ranking",
          description: "Test"
        )

        source_item = RankedItem.create!(
          item: @source_song,
          ranking_configuration: config,
          rank: 1,
          score: 95.5
        )

        source_item_id = source_item.id

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        assert_not RankedItem.exists?(source_item_id)
      end

      test "should schedule ranking recalculation jobs for affected configurations" do
        config = Music::Songs::RankingConfiguration.create!(
          name: "Test Ranking",
          description: "Test"
        )

        RankedItem.create!(
          item: @source_song,
          ranking_configuration: config,
          rank: 1
        )

        BulkCalculateWeightsJob.expects(:perform_async).with(config.id)
        CalculateRankingsJob.expects(:perform_in).with(5.minutes, config.id)

        Music::Song::Merger.call(source: @source_song, target: @target_song)
      end

      test "should schedule jobs for both source and target configurations" do
        config1 = Music::Songs::RankingConfiguration.create!(name: "Config 1", description: "Test")
        config2 = Music::Songs::RankingConfiguration.create!(name: "Config 2", description: "Test")

        RankedItem.create!(item: @source_song, ranking_configuration: config1, rank: 1)
        RankedItem.create!(item: @target_song, ranking_configuration: config2, rank: 1)

        BulkCalculateWeightsJob.expects(:perform_async).with(config1.id)
        BulkCalculateWeightsJob.expects(:perform_async).with(config2.id)
        CalculateRankingsJob.expects(:perform_in).with(5.minutes, config1.id)
        CalculateRankingsJob.expects(:perform_in).with(5.minutes, config2.id)

        Music::Song::Merger.call(source: @source_song, target: @target_song)
      end

      test "should not schedule jobs if no ranked_items exist" do
        BulkCalculateWeightsJob.expects(:perform_async).never
        CalculateRankingsJob.expects(:perform_in).never

        Music::Song::Merger.call(source: @source_song, target: @target_song)
      end

      test "should return error result on exception" do
        Music::Song::Merger.any_instance.stubs(:merge_all_associations).raises(StandardError.new("Test error"))

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Test error"], result.errors
      end

      test "should rollback on error and preserve source song" do
        source_id = @source_song.id

        Music::Song::Merger.any_instance.stubs(:destroy_source_song).raises(StandardError.new("Destruction failed"))

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert_not result.success?
        assert Music::Song.exists?(source_id)
      end

      test "should rollback track reassignment on error" do
        track = music_tracks(:dark_side_original_1)
        original_song_id = track.song_id

        Music::Song::Merger.any_instance.stubs(:destroy_source_song).raises(StandardError.new("Destruction failed"))

        Music::Song::Merger.call(source: @source_song, target: @target_song)

        track.reload
        assert_equal original_song_id, track.song_id
      end

      test "should work with class method call syntax" do
        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        assert_not Music::Song.exists?(@source_song.id)
      end

      test "should initialize with correct attributes" do
        merger = Music::Song::Merger.new(source: @source_song, target: @target_song)

        assert_equal @source_song, merger.source_song
        assert_equal @target_song, merger.target_song
        assert_equal({}, merger.stats)
      end

      test "should preserve target song artists and not merge source artists" do
        music_artists(:pink_floyd)

        initial_artists = @target_song.artists.to_a

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload

        assert_equal initial_artists.map(&:id).sort, @target_song.artists.map(&:id).sort
      end

      test "should handle songs with no associations" do
        bare_song = Music::Song.create!(title: "Bare Song", slug: "bare-song-test")
        target = Music::Song.create!(title: "Target Song", slug: "target-song-test")

        result = Music::Song::Merger.call(source: bare_song, target: target)

        assert result.success?
        assert_not Music::Song.exists?(bare_song.id)
      end

      test "should handle songs with many tracks" do
        5.times do |i|
          release = Music::Release.create!(
            album: music_albums(:dark_side_of_the_moon),
            release_name: "Release #{i}",
            format: :cd,
            status: :official
          )

          Music::Track.create!(
            release: release,
            song: @source_song,
            position: i + 1,
            medium_number: 1
          )
        end

        initial_track_count = @source_song.tracks.count

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload

        assert_operator @target_song.tracks.count, :>=, initial_track_count
      end

      test "should prevent merging a song with itself" do
        result = Music::Song::Merger.call(source: @source_song, target: @source_song)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Cannot merge a song with itself"], result.errors

        assert Music::Song.exists?(@source_song.id)
      end

      test "should handle mutual song relationships" do
        song_a = @source_song
        song_b = @target_song
        song_c = music_songs(:wish_you_were_here)

        Music::SongRelationship.create!(
          song: song_a,
          related_song: song_c,
          relation_type: :cover
        )

        Music::SongRelationship.create!(
          song: song_c,
          related_song: song_a,
          relation_type: :remix
        )

        result = Music::Song::Merger.call(source: song_a, target: song_b)

        assert result.success?

        assert Music::SongRelationship.exists?(
          song_id: song_b.id,
          related_song_id: song_c.id,
          relation_type: :cover
        )

        assert Music::SongRelationship.exists?(
          song_id: song_c.id,
          related_song_id: song_b.id,
          relation_type: :remix
        )
      end

      # Release year preservation tests
      test "should update target release_year when source year is earlier" do
        @source_song.update!(release_year: 1970)
        @target_song.update!(release_year: 1980)

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload
        assert_equal 1970, @target_song.release_year
      end

      test "should not update target release_year when source year is later" do
        @source_song.update!(release_year: 1990)
        @target_song.update!(release_year: 1980)

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload
        assert_equal 1980, @target_song.release_year
      end

      test "should not update target release_year when source year is nil" do
        @source_song.update!(release_year: nil)
        @target_song.update!(release_year: 1980)

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload
        assert_equal 1980, @target_song.release_year
      end

      test "should update target release_year when target year is nil and source has year" do
        @source_song.update!(release_year: 1975)
        @target_song.update!(release_year: nil)

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload
        assert_equal 1975, @target_song.release_year
      end

      test "should leave release_year nil when both source and target are nil" do
        @source_song.update!(release_year: nil)
        @target_song.update!(release_year: nil)

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload
        assert_nil @target_song.release_year
      end
    end
  end
end

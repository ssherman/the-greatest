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

      test "should preserve verified status when creating new list_item" do
        list = lists(:music_songs_list)

        ListItem.create!(
          list: list,
          listable: @source_song,
          position: 5,
          verified: true
        )

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload

        target_list_item = @target_song.list_items.find_by(list: list)
        assert target_list_item.present?, "Expected list_item to exist on target"
        assert target_list_item.verified?, "Expected list_item to preserve verified=true"
      end

      # Record merge is already live for music. Writing to the generated users'
      # favorites list raises RecordInvalid against the ListItem guard, so without
      # the skip this is a 500 in production admin the first time a merged song
      # happens to sit on that list. Nothing is lost: the generator rebuilds the
      # list nightly from the user favorites the merge has already moved.
      test "merges a song that sits on an auto-generated list without touching that list" do
        list = lists(:music_songs_list)
        item = ListItem.create!(list: list, listable: @source_song, position: 5, verified: true)
        list.update!(auto_generated_kind: :user_favorites)

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_nil ListItem.find_by(list: list, listable: @target_song)
        assert_not ListItem.exists?(item.id), "the source's row dies with the source song"
      end

      test "does not promote verified on an auto-generated list" do
        list = lists(:music_songs_list)
        ListItem.create!(list: list, listable: @target_song, position: 1, verified: false)
        ListItem.create!(list: list, listable: @source_song, position: 2, verified: true)
        list.update!(auto_generated_kind: :user_favorites)

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        survivor = ListItem.find_by(list: list, listable: @target_song)
        assert_not survivor.verified?, "the generator owns this row; the merger must not edit it"
      end

      # Regression: Music::Song::Merger had no merge_user_list_items at all, while
      # music_songs declares `has_many :user_list_items, dependent: :destroy`, so
      # destroying the source silently deleted every user's personal favorites entry
      # for the merged song.
      test "moves a personal list entry to the target" do
        # user_list_items(:regular_user_fav_song_1) favorites @source_song only, so
        # this exercises the no-collision branch, which repoints the row.
        entry = user_list_items(:regular_user_fav_song_1)

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal @target_song.id, entry.reload.listable_id
      end

      test "drops a personal list entry when that list already holds the target" do
        user_list = user_lists(:regular_user_music_songs_favorites)
        UserListItem.create!(user_list: user_list, listable: @target_song, position: 2)

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, UserListItem.where(user_list: user_list, listable: @target_song).count
      end

      test "a user who favorited only the source still has that favorite afterwards" do
        user_list = user_lists(:regular_user_music_songs_favorites)

        Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert UserListItem.exists?(user_list: user_list, listable: @target_song),
          "the merge must carry the user's favorite over, not destroy it with the source"
      end

      test "should preserve verified=true when merging duplicate list_items and source is verified" do
        list = lists(:music_songs_list)

        ListItem.create!(
          list: list,
          listable: @source_song,
          position: 5,
          verified: true
        )

        ListItem.create!(
          list: list,
          listable: @target_song,
          position: 10,
          verified: false
        )

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload

        target_list_item = @target_song.list_items.find_by(list: list)
        assert target_list_item.verified?, "Expected verified=true to be preserved from source"
      end

      test "should preserve verified=true when merging duplicate list_items and target is verified" do
        list = lists(:music_songs_list)

        ListItem.create!(
          list: list,
          listable: @source_song,
          position: 5,
          verified: false
        )

        ListItem.create!(
          list: list,
          listable: @target_song,
          position: 10,
          verified: true
        )

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload

        target_list_item = @target_song.list_items.find_by(list: list)
        assert target_list_item.verified?, "Expected verified=true to be preserved from target"
      end

      test "should not set verified=true when merging duplicate list_items and neither is verified" do
        list = lists(:music_songs_list)

        ListItem.create!(
          list: list,
          listable: @source_song,
          position: 5,
          verified: false
        )

        ListItem.create!(
          list: list,
          listable: @target_song,
          position: 10,
          verified: false
        )

        result = Music::Song::Merger.call(source: @source_song, target: @target_song)

        assert result.success?
        @target_song.reload

        target_list_item = @target_song.list_items.find_by(list: list)
        assert_not target_list_item.verified?, "Expected verified=false when neither source nor target was verified"
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

      # `success?` means the merge committed. Ranking recalculation is follow-up
      # work: if it fails the merge still happened, so reporting failure would send
      # the admin to a retry that fails with "not found".
      test "still reports success when scheduling ranking recalculation fails" do
        source_id = @source_song.id

        merger = Music::Song::Merger.new(source: @source_song, target: @target_song)
        merger.stubs(:schedule_ranking_recalculation).raises(StandardError.new("redis down"))

        result = merger.call

        assert result.success?,
          "a post-commit failure must not be reported as a failed merge: #{result.errors.inspect}"
        assert_not Music::Song.exists?(source_id), "the merge itself must still have committed"
        assert_equal "redis down", merger.stats[:post_commit_error]
      end

      # SearchIndexable's after_commit fires as the transaction block exits -- after
      # the commit -- and Rails propagates what it raises into call's rescue ladder.
      test "still reports success when a commit callback fails after the merge committed" do
        source_id = @source_song.id
        SearchIndexRequest.stubs(:create!).raises(StandardError.new("index store down"))

        merger = Music::Song::Merger.new(source: @source_song, target: @target_song)
        result = merger.call

        assert result.success?,
          "a commit-callback failure must not be reported as a failed merge: #{result.errors.inspect}"
        assert_not Music::Song.exists?(source_id), "the merge itself must still have committed"
        assert_equal "index store down", merger.stats[:post_commit_error]
      end

      test "reports failure when the source disappears before it can be locked" do
        # A throwaway song, so deleting it out from under the merger does not trip
        # the music_song_artists foreign key the fixtures carry.
        ghost = Music::Song.create!(title: "Ghost Song")
        merger = Music::Song::Merger.new(source: ghost, target: @target_song)
        merger.stubs(:lock_songs).raises(ActiveRecord::RecordNotFound.new("gone"))
        Music::Song.where(id: ghost.id).delete_all

        result = merger.call

        assert_not result.success?, "a merge that never ran must not report success"
        assert_equal ["gone"], result.errors
      end

      test "locks both songs for update, in ascending id order, before moving anything" do
        locked = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          sql = payload[:sql]
          next unless sql.include?("music_songs") && sql.include?("FOR UPDATE")

          binds = payload[:type_casted_binds]
          binds = binds.call if binds.respond_to?(:call)
          locked << Array(binds).first
        end

        begin
          result = Music::Song::Merger.call(source: @source_song, target: @target_song)
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        assert result.success?, "merge must succeed: #{result.errors.inspect}"
        assert_equal [@source_song.id, @target_song.id].sort, locked.compact,
          "both rows must be locked FOR UPDATE in ascending id order, or two merges " \
          "with swapped source and target can deadlock each other"
      end
    end
  end
end

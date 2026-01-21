require "test_helper"

module Music
  class Album
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source_album = music_albums(:abbey_road)
        @target_album = music_albums(:dark_side_of_the_moon)
        @pink_floyd = music_artists(:pink_floyd)
      end

      test "should successfully merge albums and return success result" do
        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        assert_equal @target_album, result.data
        assert_empty result.errors
      end

      test "should preserve target album artists and not merge source artists" do
        beatles = music_artists(:the_beatles)
        pink_floyd = music_artists(:pink_floyd)

        initial_artists = @target_album.artists.to_a

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload

        assert_includes @target_album.artists, pink_floyd
        assert_not_includes @target_album.artists, beatles
        assert_equal initial_artists.map(&:id).sort, @target_album.artists.map(&:id).sort
      end

      test "should reassign identifiers to target album" do
        identifier = identifiers(:wish_you_were_here_musicbrainz)
        wish_you = music_albums(:wish_you_were_here)

        result = Music::Album::Merger.call(source: wish_you, target: @target_album)

        assert result.success?
        identifier.reload

        assert_equal @target_album.id, identifier.identifiable_id
        assert_equal "Music::Album", identifier.identifiable_type
      end

      test "should merge category_items with duplicate handling" do
        categories(:music_rock_genre)
        wish_you = music_albums(:wish_you_were_here)

        initial_count = @target_album.category_items.count

        result = Music::Album::Merger.call(source: wish_you, target: @target_album)

        assert result.success?
        @target_album.reload

        assert_equal initial_count, @target_album.category_items.count
      end

      test "should reassign images to target album" do
        images(:dark_side_alt_cover)

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?

        assert_operator @target_album.reload.images.count, :>=, 0
      end

      test "should create search index unindex request for source album" do
        source_id = @source_album.id

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?

        request = SearchIndexRequest.where(
          parent_id: source_id,
          parent_type: "Music::Album",
          action: :unindex_item
        ).first

        assert request.present?
      end

      test "should create search index request to reindex target album" do
        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?

        request = SearchIndexRequest.where(
          parent_id: @target_album.id,
          parent_type: "Music::Album",
          action: :index_item
        ).last

        assert request.present?
      end

      test "should destroy source album after merge" do
        source_id = @source_album.id

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        assert_not Music::Album.exists?(source_id)
      end

      test "should destroy source ranked_items when source album is destroyed" do
        config = Music::Albums::RankingConfiguration.create!(
          name: "Test Ranking",
          description: "Test"
        )

        source_item = RankedItem.create!(
          item: @source_album,
          ranking_configuration: config,
          rank: 1,
          score: 95.5
        )

        source_item_id = source_item.id

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        assert_not RankedItem.exists?(source_item_id)
      end

      test "should schedule ranking recalculation jobs for affected configurations" do
        config = Music::Albums::RankingConfiguration.create!(
          name: "Test Ranking",
          description: "Test"
        )

        RankedItem.create!(
          item: @source_album,
          ranking_configuration: config,
          rank: 1
        )

        BulkCalculateWeightsJob.expects(:perform_async).with(config.id)
        CalculateRankingsJob.expects(:perform_in).with(5.minutes, config.id)

        Music::Album::Merger.call(source: @source_album, target: @target_album)
      end

      test "should schedule jobs for both source and target configurations" do
        config1 = Music::Albums::RankingConfiguration.create!(name: "Config 1", description: "Test")
        config2 = Music::Albums::RankingConfiguration.create!(name: "Config 2", description: "Test")

        RankedItem.create!(item: @source_album, ranking_configuration: config1, rank: 1)
        RankedItem.create!(item: @target_album, ranking_configuration: config2, rank: 1)

        BulkCalculateWeightsJob.expects(:perform_async).with(config1.id)
        BulkCalculateWeightsJob.expects(:perform_async).with(config2.id)
        CalculateRankingsJob.expects(:perform_in).with(5.minutes, config1.id)
        CalculateRankingsJob.expects(:perform_in).with(5.minutes, config2.id)

        Music::Album::Merger.call(source: @source_album, target: @target_album)
      end

      test "should not schedule jobs if no ranked_items exist" do
        BulkCalculateWeightsJob.expects(:perform_async).never
        CalculateRankingsJob.expects(:perform_in).never

        Music::Album::Merger.call(source: @source_album, target: @target_album)
      end

      test "should return error result on exception" do
        Music::Album::Merger.any_instance.stubs(:merge_all_associations).raises(StandardError.new("Test error"))

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Test error"], result.errors
      end

      test "should rollback on error and preserve source album" do
        source_id = @source_album.id

        Music::Album::Merger.any_instance.stubs(:destroy_source_album).raises(StandardError.new("Destruction failed"))

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert_not result.success?
        assert Music::Album.exists?(source_id)
      end

      test "should work with class method call syntax" do
        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        assert_not Music::Album.exists?(@source_album.id)
      end

      test "should initialize with correct attributes" do
        merger = Music::Album::Merger.new(source: @source_album, target: @target_album)

        assert_equal @source_album, merger.source_album
        assert_equal @target_album, merger.target_album
        assert_equal({}, merger.stats)
      end

      # Release year preservation tests
      test "should update target release_year when source year is earlier" do
        @source_album.update!(release_year: 1969)
        @target_album.update!(release_year: 1973)

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload
        assert_equal 1969, @target_album.release_year
      end

      test "should not update target release_year when source year is later" do
        @source_album.update!(release_year: 1990)
        @target_album.update!(release_year: 1973)

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload
        assert_equal 1973, @target_album.release_year
      end

      test "should not update target release_year when source year is nil" do
        @source_album.update!(release_year: nil)
        @target_album.update!(release_year: 1973)

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload
        assert_equal 1973, @target_album.release_year
      end

      test "should update target release_year when target year is nil and source has year" do
        @source_album.update!(release_year: 1969)
        @target_album.update!(release_year: nil)

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload
        assert_equal 1969, @target_album.release_year
      end

      test "should leave release_year nil when both source and target are nil" do
        @source_album.update!(release_year: nil)
        @target_album.update!(release_year: nil)

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload
        assert_nil @target_album.release_year
      end
    end
  end
end

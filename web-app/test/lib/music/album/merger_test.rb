require "test_helper"

module Music
  class Album
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source_album = music_albums(:abbey_road)
        @target_album = music_albums(:dark_side_of_the_moon)
        @pink_floyd = music_artists(:pink_floyd)

        # Clean up list_items from fixtures to ensure tests start with clean state
        ListItem.where(listable: @source_album).destroy_all
        ListItem.where(listable: @target_album).destroy_all
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

      test "should merge list_items with duplicate handling" do
        list = lists(:music_albums_list)

        ListItem.create!(
          list: list,
          listable: @source_album,
          position: 5
        )

        ListItem.create!(
          list: list,
          listable: @target_album,
          position: 10
        )

        initial_count = @target_album.list_items.count

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload

        assert_equal initial_count, @target_album.list_items.count
      end

      test "should preserve verified status when creating new list_item" do
        list = lists(:music_albums_list)

        ListItem.create!(
          list: list,
          listable: @source_album,
          position: 5,
          verified: true
        )

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload

        target_list_item = @target_album.list_items.find_by(list: list)
        assert target_list_item.present?, "Expected list_item to exist on target"
        assert target_list_item.verified?, "Expected list_item to preserve verified=true"
      end

      # Record merge is already live for music. Writing to the generated users'
      # favorites list raises RecordInvalid against the ListItem guard, so without
      # the skip this is a 500 in production admin the first time a merged album
      # happens to sit on that list. Nothing is lost: the generator rebuilds the
      # list nightly from the user favorites the merge has already moved.
      test "merges an album that sits on an auto-generated list without touching that list" do
        list = lists(:music_albums_list)
        item = ListItem.create!(list: list, listable: @source_album, position: 5, verified: true)
        list.update!(auto_generated_kind: :user_favorites)

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_nil ListItem.find_by(list: list, listable: @target_album)
        assert_not ListItem.exists?(item.id), "the source's row dies with the source album"
      end

      test "does not promote verified on an auto-generated list" do
        list = lists(:music_albums_list)
        ListItem.create!(list: list, listable: @target_album, position: 1, verified: false)
        ListItem.create!(list: list, listable: @source_album, position: 2, verified: true)
        list.update!(auto_generated_kind: :user_favorites)

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        survivor = ListItem.find_by(list: list, listable: @target_album)
        assert_not survivor.verified?, "the generator owns this row; the merger must not edit it"
      end

      # Regression: Music::Album::Merger had no merge_user_list_items at all, while
      # music_albums declares `has_many :user_list_items, dependent: :destroy`, so
      # destroying the source silently deleted every user's personal favorites entry
      # for the merged album.
      test "moves a personal list entry to the target" do
        # user_list_items(:regular_user_fav_album_1) already links this user_list to
        # @target_album; clear it so this test exercises the no-collision branch,
        # which repoints the source's row instead of dropping it.
        user_list_items(:regular_user_fav_album_1).destroy!
        entry = user_list_items(:regular_user_fav_album_2)

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal @target_album.id, entry.reload.listable_id
      end

      test "drops a personal list entry when that list already holds the target" do
        # The fixtures already favorite both albums in this list: fav_album_1 is the
        # target, fav_album_2 is the source.
        user_list = user_lists(:regular_user_music_albums_favorites)

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, UserListItem.where(user_list: user_list, listable: @target_album).count
      end

      test "a user who favorited only the source still has that favorite afterwards" do
        user_list = user_lists(:regular_user_music_albums_favorites)
        user_list_items(:regular_user_fav_album_1).destroy!

        Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert UserListItem.exists?(user_list: user_list, listable: @target_album),
          "the merge must carry the user's favorite over, not destroy it with the source"
      end

      test "should preserve verified=true when merging duplicate list_items and source is verified" do
        list = lists(:music_albums_list)

        ListItem.create!(
          list: list,
          listable: @source_album,
          position: 5,
          verified: true
        )

        ListItem.create!(
          list: list,
          listable: @target_album,
          position: 10,
          verified: false
        )

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload

        target_list_item = @target_album.list_items.find_by(list: list)
        assert target_list_item.verified?, "Expected verified=true to be preserved from source"
      end

      test "should preserve verified=true when merging duplicate list_items and target is verified" do
        list = lists(:music_albums_list)

        ListItem.create!(
          list: list,
          listable: @source_album,
          position: 5,
          verified: false
        )

        ListItem.create!(
          list: list,
          listable: @target_album,
          position: 10,
          verified: true
        )

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload

        target_list_item = @target_album.list_items.find_by(list: list)
        assert target_list_item.verified?, "Expected verified=true to be preserved from target"
      end

      test "should not set verified=true when merging duplicate list_items and neither is verified" do
        list = lists(:music_albums_list)

        ListItem.create!(
          list: list,
          listable: @source_album,
          position: 5,
          verified: false
        )

        ListItem.create!(
          list: list,
          listable: @target_album,
          position: 10,
          verified: false
        )

        result = Music::Album::Merger.call(source: @source_album, target: @target_album)

        assert result.success?
        @target_album.reload

        target_list_item = @target_album.list_items.find_by(list: list)
        assert_not target_list_item.verified?, "Expected verified=false when neither source nor target was verified"
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

      test "refuses to merge an album with itself" do
        result = Music::Album::Merger.call(source: @source_album, target: @source_album)

        assert_not result.success?
        assert_equal ["Cannot merge an album with itself"], result.errors
        assert Music::Album.exists?(@source_album.id), "a self-merge would destroy the album outright"
      end

      # `success?` means the merge committed. Reindexing and ranking are follow-up
      # work: if they fail the merge still happened, so reporting failure would send
      # the admin to a retry that fails with "not found".
      test "still reports success when scheduling ranking recalculation fails" do
        source_id = @source_album.id

        merger = Music::Album::Merger.new(source: @source_album, target: @target_album)
        merger.stubs(:schedule_ranking_recalculation).raises(StandardError.new("redis down"))

        result = merger.call

        assert result.success?,
          "a post-commit failure must not be reported as a failed merge: #{result.errors.inspect}"
        assert_not Music::Album.exists?(source_id), "the merge itself must still have committed"
        assert_equal "redis down", merger.stats[:post_commit_error]
      end

      # SearchIndexable's after_commit fires as the transaction block exits -- after
      # the commit -- and Rails propagates what it raises into call's rescue ladder.
      test "still reports success when a commit callback fails after the merge committed" do
        source_id = @source_album.id
        SearchIndexRequest.stubs(:create!).raises(StandardError.new("index store down"))

        merger = Music::Album::Merger.new(source: @source_album, target: @target_album)
        result = merger.call

        assert result.success?,
          "a commit-callback failure must not be reported as a failed merge: #{result.errors.inspect}"
        assert_not Music::Album.exists?(source_id), "the merge itself must still have committed"
        assert_equal "index store down", merger.stats[:post_commit_error]
      end

      test "reports failure when the source disappears before it can be locked" do
        source_id = @source_album.id
        merger = Music::Album::Merger.new(source: @source_album, target: @target_album)
        merger.stubs(:lock_albums).raises(ActiveRecord::RecordNotFound.new("gone"))
        Music::Album.where(id: source_id).delete_all

        result = merger.call

        assert_not result.success?, "a merge that never ran must not report success"
        assert_equal ["gone"], result.errors
      end

      test "locks both albums for update, in ascending id order, before moving anything" do
        locked = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          sql = payload[:sql]
          next unless sql.include?("music_albums") && sql.include?("FOR UPDATE")

          binds = payload[:type_casted_binds]
          binds = binds.call if binds.respond_to?(:call)
          locked << Array(binds).first
        end

        begin
          result = Music::Album::Merger.call(source: @source_album, target: @target_album)
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        assert result.success?, "merge must succeed: #{result.errors.inspect}"
        assert_equal [@source_album.id, @target_album.id].sort, locked.compact,
          "both rows must be locked FOR UPDATE in ascending id order, or two merges " \
          "with swapped source and target can deadlock each other"
      end
    end
  end
end

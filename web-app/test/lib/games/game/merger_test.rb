require "test_helper"

module Games
  class Game
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source = games_games(:half_life_2)
        @target = games_games(:breath_of_the_wild)

        # ranked_items.yml has rows for every game fixture; leaving them in place
        # makes the merger schedule real ranking jobs, which run inline in tests.
        RankedItem.where(item: @source).destroy_all
        RankedItem.where(item: @target).destroy_all
      end

      test "merges successfully and returns the target game" do
        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal @target, result.data
        assert_equal [], result.errors
      end

      test "destroys the source game" do
        source_id = @source.id

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_not ::Games::Game.exists?(source_id)
      end

      test "refuses to merge a game with itself" do
        result = ::Games::Game::Merger.call(source: @source, target: @source)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Cannot merge a game with itself"], result.errors
        assert ::Games::Game.exists?(@source.id)
      end

      test "rolls the whole merge back when a step raises" do
        ::Games::Game::Merger.any_instance.stubs(:merge_all_associations)
          .raises(StandardError.new("boom"))

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["boom"], result.errors
        assert ::Games::Game.exists?(@source.id), "source must survive a failed merge"
      end

      test "moves identifiers the target does not already have" do
        identifier = Identifier.create!(
          identifiable: @source, identifier_type: :games_igdb_id, value: "111"
        )

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_equal @target.id, identifier.reload.identifiable_id
      end

      test "drops a source identifier the target already has" do
        Identifier.create!(identifiable: @source, identifier_type: :games_igdb_id, value: "222")
        Identifier.create!(identifiable: @target, identifier_type: :games_igdb_id, value: "222")

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, Identifier.where(
          identifiable: @target, identifier_type: :games_igdb_id, value: "222"
        ).count
      end

      test "moves external links" do
        link = ExternalLink.create!(
          parent: @source,
          name: "Wikipedia",
          url: "https://example.com/hl2",
          source: :wikipedia,
          link_category: :information
        )

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.parent_id
      end

      test "demotes a moved image when the target already has a primary" do
        attach_image(@target, primary: true)
        source_image = attach_image(@source, primary: true)

        ::Games::Game::Merger.call(source: @source, target: @target)

        source_image.reload
        assert_equal @target.id, source_image.parent_id
        assert_not source_image.primary, "a second primary image would break primary_image"
      end

      test "keeps a moved image primary when the target has none" do
        source_image = attach_image(@source, primary: true)

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert source_image.reload.primary
      end

      test "copies source categories the target lacks" do
        category = categories(:games_action_genre)
        CategoryItem.create!(category: category, item: @source)

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_includes @target.reload.category_items.map(&:category_id), category.id
      end

      test "does not duplicate a category both games share" do
        category = categories(:games_action_genre)
        CategoryItem.create!(category: category, item: @source)
        CategoryItem.create!(category: category, item: @target)

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, CategoryItem.where(category: category, item: @target).count
      end

      test "moves a list item to the target" do
        list = lists(:games_list)
        # list_items(:games_item) already links games_list to @target; clear it so this
        # test exercises the no-existing-target-item branch, not the collision branch
        # (see list_item_enricher_test.rb). The no-collision branch creates a fresh row
        # on the target rather than repointing the source's, so assert by lookup.
        list_items(:games_item).destroy!
        ListItem.create!(list: list, listable: @source, position: 3, verified: false)

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert ListItem.exists?(list: list, listable: @target)
      end

      test "promotes the surviving list item to verified when the source was verified" do
        list = lists(:games_list)
        # list_items(:games_item) already links games_list to @target; clear it so the
        # explicit row below doesn't collide with it (see list_item_enricher_test.rb).
        list_items(:games_item).destroy!
        ListItem.create!(list: list, listable: @target, position: 1, verified: false)
        ListItem.create!(list: list, listable: @source, position: 2, verified: true)

        ::Games::Game::Merger.call(source: @source, target: @target)

        survivor = ListItem.find_by(list: list, listable: @target)
        assert survivor.verified, "a verified source must not silently downgrade the survivor"
        assert_equal 1, ListItem.where(list: list, listable: @target).count
      end

      test "moves a personal list entry to the target" do
        user_list = user_lists(:regular_user_games_favorites)
        # user_list_items(:regular_user_fav_game_1) already links this user_list to @target;
        # clear it so this test exercises the no-collision branch, which repoints the
        # source's row instead of dropping it.
        user_list_items(:regular_user_fav_game_1).destroy!
        entry = UserListItem.create!(user_list: user_list, listable: @source, position: 5)

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_equal @target.id, entry.reload.listable_id
      end

      test "drops a personal list entry when that list already holds the target" do
        user_list = user_lists(:regular_user_games_favorites)
        # user_list_items(:regular_user_fav_game_1) already links this user_list to @target;
        # clear it so the explicit row below doesn't collide with it.
        user_list_items(:regular_user_fav_game_1).destroy!
        UserListItem.create!(user_list: user_list, listable: @target, position: 1)
        UserListItem.create!(user_list: user_list, listable: @source, position: 2)

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, UserListItem.where(user_list: user_list, listable: @target).count
      end

      test "moves a description the target does not have" do
        description = Description.create!(
          describable: @source, content: "Source blurb",
          kind: :long, locale: "en", source: :ai_generated, rank: :normal
        )

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_equal @target.id, description.reload.describable_id
      end

      test "drops a source description that collides with the target's" do
        # descriptions(:botw_igdb) is already summary/en/igdb/preferred on the target.
        Description.create!(
          describable: @source, content: "Source blurb",
          kind: :summary, locale: "en", source: :igdb, rank: :normal
        )

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?, "collision must not raise: #{result.errors.inspect}"
        assert_equal 1, Description.where(
          describable: @target, kind: :summary, locale: "en", source: :igdb
        ).count
      end

      test "demotes a moved description when the target already has a preferred one" do
        # descriptions(:botw_igdb) is already summary/en/preferred on the target. A different
        # source avoids the composite index but still hits the one-preferred-per-key index.
        moved = Description.create!(
          describable: @source, content: "Other", kind: :summary, locale: "en",
          source: :ai_generated, rank: :preferred
        )

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?,
          "two preferred rows would violate the partial unique index: #{result.errors.inspect}"
        assert_equal "normal", moved.reload.rank
        assert_equal @target.id, moved.describable_id
      end

      test "moves a company link the target does not have" do
        link = games_game_companies(:hl2_valve_dev)

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.game_id
      end

      test "ORs developer and publisher flags when both games share a company" do
        company = games_companies(:nintendo)
        ::Games::GameCompany.where(game: @source, company: company).destroy_all
        ::Games::GameCompany.create!(game: @source, company: company, developer: false, publisher: true)
        target_link = ::Games::GameCompany.find_by(game: @target, company: company)
        target_link.update!(developer: true, publisher: false)

        ::Games::Game::Merger.call(source: @source, target: @target)

        target_link.reload
        assert target_link.developer, "the target's own developer flag must survive"
        assert target_link.publisher, "the source's publisher flag must not be discarded"
        assert_equal 1, ::Games::GameCompany.where(game: @target, company: company).count
      end

      test "moves a platform link the target does not have" do
        link = games_game_platforms(:hl2_pc)

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.game_id
      end

      test "drops a platform link both games share" do
        platform = games_platforms(:pc)
        ::Games::GamePlatform.find_or_create_by!(game: @target, platform: platform)

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, ::Games::GamePlatform.where(game: @target, platform: platform).count
      end

      test "repoints child games to the target instead of orphaning them" do
        source = games_games(:resident_evil_4)
        target = games_games(:half_life_2)
        child = games_games(:resident_evil_4_remake)
        RankedItem.where(item: source).destroy_all
        RankedItem.where(item: target).destroy_all

        ::Games::Game::Merger.call(source: source, target: target)

        assert_equal target.id, child.reload.parent_game_id,
          "child_games is dependent: :nullify, so doing nothing orphans the subtree"
      end

      test "nullifies rather than self-parents when the target is a child of the source" do
        source = games_games(:resident_evil_4)
        target = games_games(:resident_evil_4_remake)
        RankedItem.where(item: source).destroy_all
        RankedItem.where(item: target).destroy_all

        result = ::Games::Game::Merger.call(source: source, target: target)

        assert result.success?, "a game cannot be its own parent: #{result.errors.inspect}"
        assert_nil target.reload.parent_game_id
      end

      test "fills a blank description from the source" do
        @source.update!(description: "A source blurb")
        @target.update!(description: nil)

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_equal "A source blurb", @target.reload.description
      end

      test "never overwrites a field the target already has" do
        @source.update!(description: "Source wins?")
        @target.update!(description: "Target's own")

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal "Target's own", @target.reload.description
      end

      test "fills a blank series from the source" do
        source = games_games(:resident_evil_4)
        target = games_games(:half_life_2)
        RankedItem.where(item: source).destroy_all
        RankedItem.where(item: target).destroy_all
        assert_nil target.series_id, "fixture precondition"

        ::Games::Game::Merger.call(source: source, target: target)

        assert_equal source.series_id, target.reload.series_id
      end

      test "keeps the earliest release year" do
        @source.update!(release_year: 1998)
        @target.update!(release_year: 2017)

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_equal 1998, @target.reload.release_year
      end

      test "does not move the release year later" do
        @source.update!(release_year: 2020)
        @target.update!(release_year: 2017)

        result = ::Games::Game::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 2017, @target.reload.release_year
      end

      test "does not give a main game a parent" do
        source = games_games(:resident_evil_4_remake)
        target = games_games(:half_life_2)
        RankedItem.where(item: source).destroy_all
        RankedItem.where(item: target).destroy_all
        assert target.main_game?, "fixture precondition"

        result = ::Games::Game::Merger.call(source: source, target: target)

        assert result.success?, "parent_game_valid_for_type would reject this: #{result.errors.inspect}"
        assert_nil target.reload.parent_game_id
      end

      def attach_image(game, primary:)
        game.images.create!(primary: primary) do |image|
          image.file.attach(
            io: StringIO.new("fake image data"),
            filename: "cover.jpg",
            content_type: "image/jpeg"
          )
        end
      end
    end
  end
end

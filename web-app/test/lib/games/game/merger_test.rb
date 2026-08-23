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

        ::Games::Game::Merger.call(source: @source, target: @target)

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

        ::Games::Game::Merger.call(source: @source, target: @target)

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

        ::Games::Game::Merger.call(source: @source, target: @target)

        assert_equal 1, CategoryItem.where(category: category, item: @target).count
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

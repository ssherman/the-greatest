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
    end
  end
end

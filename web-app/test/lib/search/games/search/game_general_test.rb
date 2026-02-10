# frozen_string_literal: true

require "test_helper"

module Search
  module Games
    module Search
      class GameGeneralTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Games::GameIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "index_name includes Rails environment" do
          index_name = ::Search::Games::Search::GameGeneral.index_name
          assert_match(/^games_games_test/, index_name)
          assert_match(/games_games_test_\d+/, index_name)
        end

        test "call returns empty array for blank text" do
          result = ::Search::Games::Search::GameGeneral.call("")
          assert_equal [], result

          result = ::Search::Games::Search::GameGeneral.call(nil)
          assert_equal [], result
        end

        test "call finds games by title" do
          game = games_games(:breath_of_the_wild)
          ::Search::Games::GameIndex.index(game)
          sleep(0.1)

          results = ::Search::Games::Search::GameGeneral.call("Zelda Breath")

          assert_equal 1, results.size
          assert_equal game.id.to_s, results[0][:id]
          assert results[0][:score] > 0
          assert_equal "The Legend of Zelda: Breath of the Wild", results[0][:source]["title"]
        end

        test "call finds games by developer name" do
          game = games_games(:breath_of_the_wild)
          ::Search::Games::GameIndex.index(game)
          sleep(0.1)

          results = ::Search::Games::Search::GameGeneral.call("Nintendo")

          assert_equal 1, results.size
          assert_equal game.id.to_s, results[0][:id]
        end

        test "call returns results ordered by relevance" do
          game1 = games_games(:resident_evil_4)
          game2 = games_games(:resident_evil_4_remake)
          ::Search::Games::GameIndex.index(game1)
          ::Search::Games::GameIndex.index(game2)
          sleep(0.1)

          results = ::Search::Games::Search::GameGeneral.call("Resident Evil 4")

          assert_equal 2, results.size
          assert results[0][:score] >= results[1][:score]
        end

        test "call with custom options" do
          game = games_games(:half_life_2)
          ::Search::Games::GameIndex.index(game)
          sleep(0.1)

          results = ::Search::Games::Search::GameGeneral.call("Half-Life", {
            size: 1,
            from: 0,
            min_score: 0.5
          })

          assert_equal 1, results.size
          assert_equal game.id.to_s, results[0][:id]
        end

        private

        def cleanup_test_index
          ::Search::Games::GameIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end

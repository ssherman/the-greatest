# frozen_string_literal: true

require "test_helper"

module Search
  module Games
    module Search
      class GameAutocompleteTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Games::GameIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "index_name includes Rails environment" do
          index_name = ::Search::Games::Search::GameAutocomplete.index_name
          assert_match(/^games_games_test/, index_name)
          assert_match(/games_games_test_\d+/, index_name)
        end

        test "call returns empty array for blank text" do
          result = ::Search::Games::Search::GameAutocomplete.call("")
          assert_equal [], result

          result = ::Search::Games::Search::GameAutocomplete.call(nil)
          assert_equal [], result
        end

        test "call finds games by prefix" do
          game = games_games(:breath_of_the_wild)
          ::Search::Games::GameIndex.index(game)
          sleep(0.1)

          results = ::Search::Games::Search::GameAutocomplete.call("leg")

          assert_equal 1, results.size
          assert_equal game.id.to_s, results[0][:id]
        end

        test "call finds multiple games matching prefix" do
          game1 = games_games(:resident_evil_4)
          game2 = games_games(:resident_evil_4_remake)
          ::Search::Games::GameIndex.index(game1)
          ::Search::Games::GameIndex.index(game2)
          sleep(0.1)

          results = ::Search::Games::Search::GameAutocomplete.call("res")

          assert_equal 2, results.size
        end

        test "call uses lower min_score than general search" do
          game = games_games(:half_life_2)
          ::Search::Games::GameIndex.index(game)
          sleep(0.1)

          # Autocomplete should find with partial match
          results = ::Search::Games::Search::GameAutocomplete.call("hal")

          assert results.size >= 1
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

# frozen_string_literal: true

require "test_helper"

module Search
  module Games
    class GameIndexTest < ActiveSupport::TestCase
      def setup
        cleanup_test_index
      end

      def teardown
        cleanup_test_index
      end

      test "index_name includes Rails environment" do
        index_name = ::Search::Games::GameIndex.index_name
        assert_match(/^games_games_test/, index_name)
        # In test environment, should include process ID for parallel testing
        assert_match(/games_games_test_\d+/, index_name)
      end

      test "index_definition returns correct mapping structure" do
        definition = ::Search::Games::GameIndex.index_definition

        assert definition[:settings][:analysis][:analyzer][:folding]
        assert_equal "standard", definition[:settings][:analysis][:analyzer][:folding][:tokenizer]
        assert_equal ["lowercase", "asciifolding"], definition[:settings][:analysis][:analyzer][:folding][:filter]

        properties = definition[:mappings][:properties]
        assert properties[:title]
        assert_equal "text", properties[:title][:type]
        assert_equal "folding", properties[:title][:analyzer]
        assert properties[:title][:fields][:keyword]
        assert_equal "keyword", properties[:title][:fields][:keyword][:type]
        assert_equal "lowercase", properties[:title][:fields][:keyword][:normalizer]
        assert properties[:title][:fields][:autocomplete]

        assert properties[:developer_names]
        assert_equal "text", properties[:developer_names][:type]
        assert properties[:developer_names][:fields][:keyword]

        assert properties[:developer_ids]
        assert_equal "keyword", properties[:developer_ids][:type]

        assert properties[:platform_ids]
        assert_equal "keyword", properties[:platform_ids][:type]

        assert properties[:category_ids]
        assert_equal "keyword", properties[:category_ids][:type]
      end

      test "can create and delete index" do
        ::Search::Games::GameIndex.create_index
        assert ::Search::Games::GameIndex.index_exists?

        ::Search::Games::GameIndex.delete_index
        assert_not ::Search::Games::GameIndex.index_exists?
      end

      test "can index and find game" do
        ::Search::Games::GameIndex.create_index

        game = games_games(:breath_of_the_wild)
        ::Search::Games::GameIndex.index(game)

        sleep(0.1)

        result = ::Search::Games::GameIndex.find(game.id)
        assert_equal "The Legend of Zelda: Breath of the Wild", result["title"]
      end

      test "model_klass returns Games::Game" do
        assert_equal ::Games::Game, ::Search::Games::GameIndex.model_klass
      end

      test "model_includes returns associations for eager loading" do
        includes = ::Search::Games::GameIndex.model_includes
        assert_includes includes, :companies
        assert_includes includes, :platforms
      end

      private

      def cleanup_test_index
        ::Search::Games::GameIndex.delete_index
      rescue OpenSearch::Transport::Transport::Errors::NotFound
        # Index doesn't exist, that's fine
      end
    end
  end
end

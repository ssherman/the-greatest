# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    class AuthorIndexTest < ActiveSupport::TestCase
      def setup
        cleanup_test_index
      end

      def teardown
        cleanup_test_index
      end

      test "index_name includes Rails environment" do
        index_name = ::Search::Books::AuthorIndex.index_name
        assert_match(/^books_authors_test/, index_name)
        assert_match(/books_authors_test_\d+/, index_name)
      end

      test "index_definition returns correct mapping structure" do
        definition = ::Search::Books::AuthorIndex.index_definition

        properties = definition[:mappings][:properties]
        assert_equal "text", properties[:name][:type]
        assert_equal "folding", properties[:name][:analyzer]
        assert_equal "keyword", properties[:name][:fields][:keyword][:type]
        assert_equal "autocomplete", properties[:name][:fields][:autocomplete][:analyzer]
        assert_equal "text", properties[:alternate_names][:type]
        assert_equal "keyword", properties[:category_ids][:type]
      end

      test "can create and delete index" do
        ::Search::Books::AuthorIndex.create_index
        assert ::Search::Books::AuthorIndex.index_exists?

        ::Search::Books::AuthorIndex.delete_index
        assert_not ::Search::Books::AuthorIndex.index_exists?
      end

      test "can index and find author" do
        ::Search::Books::AuthorIndex.create_index

        author = books_authors(:tolstoy)
        ::Search::Books::AuthorIndex.index(author)
        sleep(0.1)

        result = ::Search::Books::AuthorIndex.find(author.id)
        assert_equal "Leo Tolstoy", result["name"]
        assert_includes result["alternate_names"], "Lev Tolstoy"
      end

      private

      def cleanup_test_index
        ::Search::Books::AuthorIndex.delete_index
      rescue OpenSearch::Transport::Transport::Errors::NotFound
      end
    end
  end
end

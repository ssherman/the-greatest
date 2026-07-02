# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    class BookIndexTest < ActiveSupport::TestCase
      def setup
        cleanup_test_index
      end

      def teardown
        cleanup_test_index
      end

      test "index_name includes Rails environment" do
        index_name = ::Search::Books::BookIndex.index_name
        assert_match(/^books_books_test/, index_name)
        assert_match(/books_books_test_\d+/, index_name)
      end

      test "index_definition returns correct mapping structure" do
        definition = ::Search::Books::BookIndex.index_definition

        assert definition[:settings][:analysis][:analyzer][:folding]
        assert_equal "standard", definition[:settings][:analysis][:analyzer][:folding][:tokenizer]
        assert_equal [ "lowercase", "asciifolding" ], definition[:settings][:analysis][:analyzer][:folding][:filter]

        properties = definition[:mappings][:properties]
        assert_equal "text", properties[:title][:type]
        assert_equal "folding", properties[:title][:analyzer]
        assert_equal "keyword", properties[:title][:fields][:keyword][:type]
        assert_equal "autocomplete", properties[:title][:fields][:autocomplete][:analyzer]
        assert_equal "autocomplete_search", properties[:title][:fields][:autocomplete][:search_analyzer]
        assert_equal "text", properties[:subtitle][:type]
        assert_equal "text", properties[:alternate_titles][:type]
        assert_equal "text", properties[:author_names][:type]
        assert_equal "keyword", properties[:author_ids][:type]
        assert_equal "keyword", properties[:category_ids][:type]
        assert_equal "keyword", properties[:book_kind][:type]
      end

      test "can create and delete index" do
        ::Search::Books::BookIndex.create_index
        assert ::Search::Books::BookIndex.index_exists?

        ::Search::Books::BookIndex.delete_index
        assert_not ::Search::Books::BookIndex.index_exists?
      end

      test "can index and find book" do
        ::Search::Books::BookIndex.create_index

        book = books_books(:war_and_peace)
        ::Search::Books::BookIndex.index(book)
        sleep(0.1)

        result = ::Search::Books::BookIndex.find(book.id)
        assert_equal "War and Peace", result["title"]
        assert_equal "standalone", result["book_kind"]
        assert_includes result["author_names"], "Leo Tolstoy"
      end

      private

      def cleanup_test_index
        ::Search::Books::BookIndex.delete_index
      rescue OpenSearch::Transport::Transport::Errors::NotFound
      end
    end
  end
end

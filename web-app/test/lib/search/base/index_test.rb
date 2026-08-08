# frozen_string_literal: true

require "test_helper"

module Search
  module Base
    class IndexBulkUpdateTest < ActiveSupport::TestCase
      def setup
        cleanup_test_index
        ::Search::Books::BookIndex.create_index
      end

      def teardown
        cleanup_test_index
      end

      test "bulk_update patches only the named fields and leaves the rest intact" do
        book = books_books(:war_and_peace)
        ::Search::Books::BookIndex.index_item(book)

        ::Search::Books::BookIndex.bulk_update(book.id => {ranked: true, ranked_position: 12})

        doc = ::Search::Books::BookIndex.find_by_id(book.id)
        assert_equal 12, doc["ranked_position"]
        assert_equal true, doc["ranked"]
        assert_equal book.title, doc["title"]
      end

      test "bulk_update is a no-op for an empty hash" do
        assert_nil ::Search::Books::BookIndex.bulk_update({})
      end

      test "bulk_update applies each document its own values" do
        first = books_books(:war_and_peace)
        second = ::Books::Book.create!(title: "Second Indexed Book")
        ::Search::Books::BookIndex.index_item(first)
        ::Search::Books::BookIndex.index_item(second)

        ::Search::Books::BookIndex.bulk_update(
          first.id => {ranked_position: 1},
          second.id => {ranked_position: 2}
        )

        assert_equal 1, ::Search::Books::BookIndex.find_by_id(first.id)["ranked_position"]
        assert_equal 2, ::Search::Books::BookIndex.find_by_id(second.id)["ranked_position"]
      end

      private

      def cleanup_test_index
        ::Search::Books::BookIndex.delete_index
      rescue OpenSearch::Transport::Transport::Errors::NotFound
      end
    end
  end
end

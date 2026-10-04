# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookAutocompleteTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "call returns empty array for blank text" do
          assert_equal [], ::Search::Books::Search::BookAutocomplete.call("")
          assert_equal [], ::Search::Books::Search::BookAutocomplete.call(nil)
        end

        test "call finds books with partial prefix match" do
          book = books_books(:crime_and_punishment)
          ::Search::Books::BookIndex.index(book)
          sleep(0.1)

          results = ::Search::Books::Search::BookAutocomplete.call("cri")

          assert_equal 1, results.size
          assert_equal book.id.to_s, results[0][:id]
          assert results[0][:score] > 0
        end

        test "call excludes collection books" do
          standalone = books_books(:of_mice_and_men)
          collection = books_books(:combo_steinbeck)
          ::Search::Books::BookIndex.index(standalone)
          ::Search::Books::BookIndex.index(collection)
          sleep(0.1)

          results = ::Search::Books::Search::BookAutocomplete.call("Of Mice")
          ids = results.map { |r| r[:id] }

          assert_includes ids, standalone.id.to_s
          assert_not_includes ids, collection.id.to_s
        end

        test "call includes collection books when book_kind is nil" do
          standalone = books_books(:of_mice_and_men)
          collection = books_books(:combo_steinbeck)
          ::Search::Books::BookIndex.index(standalone)
          ::Search::Books::BookIndex.index(collection)
          sleep(0.1)

          results = ::Search::Books::Search::BookAutocomplete.call("Of Mice", book_kind: nil)
          ids = results.map { |r| r[:id] }

          assert_includes ids, collection.id.to_s
        end

        def index_doc(id, attrs = {})
          ::Search::Base::Search.client.index(
            index: ::Search::Books::BookIndex.index_name,
            id: id,
            body: {title: "Book #{id}", book_kind: "standalone", author_names: [], alternate_titles: []}.merge(attrs),
            refresh: true
          )
        end

        test "call leaves out provisional books" do
          index_doc(1, title: "Quiet Harbour", provisional: false)
          index_doc(2, title: "Quiet Harbour", provisional: true)

          ids = ::Search::Books::Search::BookAutocomplete.call("Quiet Harb").map { |hit| hit[:id] }

          assert_equal ["1"], ids
        end

        test "call includes provisional books when asked" do
          index_doc(2, title: "Quiet Harbour", provisional: true)

          ids = ::Search::Books::Search::BookAutocomplete.call("Quiet Harb", include_provisional: true).map { |hit| hit[:id] }

          assert_equal ["2"], ids
        end

        test "a document with no provisional field is still found" do
          index_doc(3, title: "Quiet Harbour")

          ids = ::Search::Books::Search::BookAutocomplete.call("Quiet Harb").map { |hit| hit[:id] }

          assert_equal ["3"], ids
        end

        private

        def cleanup_test_index
          ::Search::Books::BookIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end

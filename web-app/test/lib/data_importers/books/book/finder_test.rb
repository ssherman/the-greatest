# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class FinderTest < ActiveSupport::TestCase
        def setup
          @finder = Finder.new
        end

        test "finds by books_work_openlibrary_id" do
          identifier = identifiers(:crime_and_punishment_openlibrary)
          query = ImportQuery.new(title: nil, open_library_work_key: identifier.value)

          result = @finder.call(query: query)

          assert_equal books_books(:crime_and_punishment), result
        end

        test "finds by books_work_isbn13" do
          identifier = identifiers(:war_and_peace_isbn13)
          query = ImportQuery.new(title: nil, isbn13: [identifier.value])

          result = @finder.call(query: query)

          assert_equal books_books(:war_and_peace), result
        end

        test "finds by books_work_goodreads_id" do
          identifier = identifiers(:of_mice_and_men_goodreads)
          query = ImportQuery.new(title: nil, goodreads_id: [identifier.value])

          result = @finder.call(query: query)

          assert_equal books_books(:of_mice_and_men), result
        end

        test "identifier lookup wins over a title match" do
          identifier = identifiers(:crime_and_punishment_openlibrary)
          query = ImportQuery.new(
            title: "War and Peace",
            author_names: ["Leo Tolstoy"],
            open_library_work_key: identifier.value
          )

          result = @finder.call(query: query)

          assert_equal books_books(:crime_and_punishment), result
        end

        test "title + author fallback finds an exact case-insensitive match" do
          query = ImportQuery.new(title: "war and peace", author_names: ["LEO TOLSTOY"])

          result = @finder.call(query: query)

          assert_equal books_books(:war_and_peace), result
        end

        test "title alone with no author names returns nil even when the title exists" do
          query = ImportQuery.new(title: "War and Peace")

          result = @finder.call(query: query)

          assert_nil result
        end

        test "title with a non-matching author returns nil" do
          query = ImportQuery.new(title: "War and Peace", author_names: ["Someone Else"])

          result = @finder.call(query: query)

          assert_nil result
        end

        test "returns nil when nothing matches" do
          query = ImportQuery.new(title: "A Book That Does Not Exist", author_names: ["Nobody"])

          result = @finder.call(query: query)

          assert_nil result
        end

        test "makes no HTTP request" do
          query = ImportQuery.new(
            title: "War and Peace",
            author_names: ["Leo Tolstoy"],
            isbn13: ["9780140447934"],
            open_library_work_key: "OL262758W"
          )

          @finder.call(query: query)

          assert_not_requested(:any, /.*/)
        end
      end
    end
  end
end

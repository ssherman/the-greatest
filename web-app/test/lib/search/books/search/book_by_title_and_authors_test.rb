# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class BookByTitleAndAuthorsTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::BookIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        def index(*books)
          books.each { |book| ::Search::Books::BookIndex.index(book) }
          sleep(0.1)
        end

        test "index_name delegates to BookIndex" do
          assert_equal ::Search::Books::BookIndex.index_name, ::Search::Books::Search::BookByTitleAndAuthors.index_name
        end

        test "returns an empty array for a blank title without searching" do
          ::Search::Books::Search::BookByTitleAndAuthors.expects(:search).never

          assert_equal [], ::Search::Books::Search::BookByTitleAndAuthors.call(title: "", authors: ["Leo Tolstoy"])
          assert_equal [], ::Search::Books::Search::BookByTitleAndAuthors.call(title: nil)
        end

        test "returns an empty array without searching when the title normalizes to nothing" do
          ::Search::Books::Search::BookByTitleAndAuthors.expects(:search).never

          assert_equal [], ::Search::Books::Search::BookByTitleAndAuthors.call(title: "***")
        end

        test "finds a book by title and author" do
          book = books_books(:war_and_peace)
          index(book, books_books(:crime_and_punishment))

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "War and Peace", authors: ["Leo Tolstoy"])

          assert_equal [book.id.to_s], results.map { |hit| hit[:id] }
          assert results[0][:score] > 0
        end

        test "finds a book whose alternate title is the query title" do
          book = books_books(:war_and_peace)
          index(book)

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "Voyna i mir", authors: ["Leo Tolstoy"])

          assert_equal [book.id.to_s], results.map { |hit| hit[:id] }
        end

        test "an accented query finds the accented title, and so does its ASCII spelling" do
          book = ::Books::Book.create!(title: "Trilogía De Las Fundaciones")
          index(book)

          assert_equal [book.id.to_s], ::Search::Books::Search::BookByTitleAndAuthors.call(title: "Trilogía De Las Fundaciones").map { |hit| hit[:id] }
          assert_equal [book.id.to_s], ::Search::Books::Search::BookByTitleAndAuthors.call(title: "Trilogia de las Fundaciones").map { |hit| hit[:id] }
        end

        test "authors are optional: a title-only query still finds the book" do
          book = books_books(:war_and_peace)
          index(book)

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "War and Peace")

          assert_equal [book.id.to_s], results.map { |hit| hit[:id] }
        end

        test "a title-only query uses a higher minimum score than a title-plus-authors query" do
          definition = ::Search::Books::Search::BookByTitleAndAuthors.build_query_definition("War and Peace", [], nil, nil, 5, 0)
          with_authors = ::Search::Books::Search::BookByTitleAndAuthors.build_query_definition("War and Peace", ["Leo Tolstoy"], nil, nil, 5, 0)

          assert_equal 8.0, definition[:min_score]
          assert_equal 5.0, with_authors[:min_score]
        end

        test "min_score keys off the built author clauses, not the raw author list" do
          definition = ::Search::Books::Search::BookByTitleAndAuthors.build_query_definition("War and Peace", ["***"], nil, nil, 5, 0)

          assert_equal 8.0, definition[:min_score]
        end

        test "an explicit min_score overrides the default" do
          definition = ::Search::Books::Search::BookByTitleAndAuthors.build_query_definition("War and Peace", [], nil, 2.5, 5, 0)

          assert_equal 2.5, definition[:min_score]
        end

        test "a year within one of the query year ranks first among same-titled books" do
          old = ::Books::Book.create!(title: "Dune", first_published_year: 1965)
          reissue = ::Books::Book.create!(title: "Dune", first_published_year: 2021)
          index(old, reissue)

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "Dune", year: 2020)

          assert_equal [reissue.id.to_s, old.id.to_s], results.map { |hit| hit[:id] }
        end

        test "a wrong author does not exclude a title match" do
          book = books_books(:war_and_peace)
          index(book)

          results = ::Search::Books::Search::BookByTitleAndAuthors.call(title: "War and Peace", authors: ["Someone Else"])

          assert_equal [book.id.to_s], results.map { |hit| hit[:id] }
        end

        test "respects size" do
          first = ::Books::Book.create!(title: "Dune", first_published_year: 1965)
          second = ::Books::Book.create!(title: "Dune", first_published_year: 2021)
          index(first, second)

          assert_equal 2, ::Search::Books::Search::BookByTitleAndAuthors.call(title: "Dune").size
          assert_equal 1, ::Search::Books::Search::BookByTitleAndAuthors.call(title: "Dune", size: 1).size
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

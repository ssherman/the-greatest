# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    # catch_22_* are real searches, no_results and beloved_title_only were
    # fetched 2026-10-25; redesigned.html is synthetic.
    class SearchPageTest < ActiveSupport::TestCase
      def search_html(name)
        path = file_fixture("goodreads/searches/#{name}")
        html = name.end_with?(".gz") ? Zlib.gunzip(path.binread) : path.binread
        html.force_encoding(Encoding::UTF_8)
      end

      test "a title and author search yields its 20 rows with ids, authors, counts and year" do
        parsed = SearchPage.parse(html: search_html("catch_22_title_and_author.html.gz"), status: 200)

        assert_equal [:found, 20], [parsed.outcome, parsed.rows.size]
        first, second, third = parsed.rows
        assert_equal [6860652, ["Novel Units, Inc."], 169, 1, 2008],
          [first.goodreads_book_id, first.author_names, first.ratings_count, first.editions_count, first.year]
        assert_equal [147719920, ["Joseph Heller"], 907_547, 521, 1961],
          [third.goodreads_book_id, third.author_names, third.ratings_count, third.editions_count, third.year]
        assert_nil second.year
      end

      test "a title-only search reads titles with the series suffix intact" do
        parsed = SearchPage.parse(html: search_html("catch_22_title_only.html.gz"), status: 200)

        first, second = parsed.rows
        assert_equal [168668, "Catch-22", ["Joseph Heller"], 907_547],
          [first.goodreads_book_id, first.title, first.author_names, first.ratings_count]
        assert_equal "Closing Time (Catch-22, #2)", second.title
      end

      test "a real search for a famous title is found" do
        parsed = SearchPage.parse(html: search_html("beloved_title_only.html.gz"), status: 200)

        assert_equal :found, parsed.outcome
        assert_predicate parsed.rows, :any?
      end

      test "Goodreads' no-results page is no_results with no rows" do
        parsed = SearchPage.parse(html: search_html("no_results.html.gz"), status: 200)

        assert_equal [:no_results, []], [parsed.outcome, parsed.rows]
      end

      test "a 200 page with neither rows nor the no-results text is unparseable" do
        parsed = SearchPage.parse(html: search_html("redesigned.html"), status: 200)

        assert_equal [:unparseable, []], [parsed.outcome, parsed.rows]
      end

      test "401, 403 and 429 are blocked and 5xx is unavailable" do
        assert_equal [:blocked, :blocked, :blocked, :unavailable],
          [401, 403, 429, 503].map { |status| SearchPage.parse(html: "", status: status).outcome }
      end
    end
  end
end

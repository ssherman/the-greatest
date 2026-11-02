# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    # catch_22_* are real searches, no_results and beloved_title_only were
    # fetched 2026-10-25; redesigned.html is synthetic. The *_redesign_2026_11
    # pages are real searches in the card layout Goodreads moved to in
    # November 2026, trimmed to three results (scripts, styles and images out).
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

      test "the November 2026 card layout yields each result once, with the series in the old suffix form" do
        parsed = SearchPage.parse(html: search_html("jojo_redesign_2026_11.html.gz"), status: 200)

        assert_equal [:found, [22545983, 7698607, 25398914]], [parsed.outcome, parsed.rows.map(&:goodreads_book_id)]
        first, second, third = parsed.rows
        assert_equal ["JoJo's Bizarre Adventure: Part 1—Phantom Blood, Vol. 1 (Phantom Blood Deluxe, #1)", ["Hirohiko Araki"], 2015, 27],
          [first.title, first.author_names, first.year, first.editions_count]
        assert_equal [6677, 5, 2004], [second.ratings_count, second.editions_count, second.year]
        assert_equal ["Hirohiko Araki", "Evan Galloway"], third.author_names
      end

      test "an abbreviated ratings count reads as its whole number" do
        parsed = SearchPage.parse(html: search_html("jojo_redesign_2026_11.html.gz"), status: 200)

        assert_equal 12_000, parsed.rows.first.ratings_count
      end

      test "the card layout's no-results page is no_results" do
        parsed = SearchPage.parse(html: search_html("no_results_redesign_2026_11.html.gz"), status: 200)

        assert_equal [:no_results, []], [parsed.outcome, parsed.rows]
      end

      test "a 200 Goodreads page with neither rows nor the no-results text is unparseable" do
        parsed = SearchPage.parse(html: search_html("redesigned.html"), status: 200)

        assert_equal [:unparseable, []], [parsed.outcome, parsed.rows]
      end

      # Only an unreadable page Goodreads itself served may end one book without
      # closing the gate; anything else stands in for a challenge.
      test "a page that is not Goodreads', or any other status it cannot read, is blocked" do
        challenge = file_fixture("goodreads/pages/synthetic_challenge.html").read
        redesigned = search_html("redesigned.html")

        assert_equal [:blocked] * 4, [[challenge, 200], ["", 200], [redesigned, 202], [redesigned, 405]].map { |html, status| SearchPage.parse(html: html, status: status).outcome }
      end

      test "401, 403 and 429 are blocked and 5xx is unavailable" do
        assert_equal [:blocked, :blocked, :blocked, :unavailable],
          [401, 403, 429, 503].map { |status| SearchPage.parse(html: "", status: status).outcome }
      end
    end
  end
end

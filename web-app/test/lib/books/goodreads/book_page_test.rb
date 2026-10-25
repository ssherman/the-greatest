# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    # The fixtures are real Goodreads pages fetched 2026-10-04 (apiKey
    # redacted), except synthetic_challenge.html: no fetch was ever blocked.
    class BookPageTest < ActiveSupport::TestCase
      def page_html(name)
        path = file_fixture("goodreads/pages/#{name}")
        html = name.end_with?(".gz") ? Zlib.gunzip(path.binread) : path.binread
        html.force_encoding(Encoding::UTF_8)
      end

      def contributors(facts)
        facts.contributors.map { |contributor| [contributor.name, contributor.role, contributor.primary] }
      end

      test "War and Peace from __NEXT_DATA__: translators are contributors, never creators" do
        parsed = BookPage.parse(html: page_html("war_and_peace_656.html.gz"), status: 200)

        facts = parsed.facts
        assert parsed.found?
        assert_equal [656, "War and Peace", [], 1868], [facts.goodreads_book_id, facts.title,
          facts.series, facts.original_publication_year]
        assert_equal ["9780192833983", "0192833987", nil], [facts.isbn13, facts.isbn10, facts.asin]
        assert_equal [["Leo Tolstoy", "Author", true], ["Aylmer Maude", "Translator", false],
          ["Louise Maude", "Translator", false]], contributors(facts)
        assert_equal ["Leo Tolstoy"], facts.contributors.select(&:creator?).map(&:name)
      end

      test "a comic's writers are its creators, its illustrators are not, and the subtitle stays" do
        facts = BookPage.parse(html: page_html("batman_writers_26067585.html.gz"), status: 200).facts

        assert_equal "Batman, Volume 8: Superheavy", facts.title
        assert_equal [BookPage::Series.new(goodreads_series_id: 130291, title: "Batman (2011)", position: nil)], facts.series
        assert_equal ["Scott Snyder", "Brian Azzarello"], facts.contributors.select(&:creator?).map(&:name)
        assert_equal %w[Illustrator Illustrator Illustrator], facts.contributors.reject(&:creator?).map(&:role)
      end

      test "an unclosed series suffix comes off the title and the series is read" do
        facts = BookPage.parse(html: page_html("series_unclosed_18912323.html.gz"), status: 200).facts

        assert_equal ["The Corpse in Oozak's Pond", 1987], [facts.title, facts.original_publication_year]
        assert_equal [BookPage::Series.new(goodreads_series_id: 45305, title: "Peter Shandy", position: "6")], facts.series
        assert_equal ["9781453278772", "145327877X", "B009S33K70"], [facts.isbn13, facts.isbn10, facts.asin]
      end

      test "a page without __NEXT_DATA__ is read from its markup and linked data" do
        facts = BookPage.parse(html: page_html("no_next_data_129650.html.gz"), status: 200).facts

        assert_equal [129650, "Mastering the Art of French Cooking", 1961],
          [facts.goodreads_book_id, facts.title, facts.original_publication_year]
        assert_equal [BookPage::Series.new(goodreads_series_id: 77378, title: "Mastering the Art of French Cooking", position: "1")],
          facts.series
        assert_equal ["9780375413407", "0375413405"], [facts.isbn13, facts.isbn10]
        assert_equal [["Julia Child", "Author", true], ["Sidonie Coryn", "Illustrator", false],
          ["Louisette Bertholle", "Author", false], ["Simone Beck", nil, false]], contributors(facts)
        assert_equal ["Julia Child", "Louisette Bertholle"], facts.contributors.select(&:creator?).map(&:name)
      end

      test "the markup path reads what __NEXT_DATA__ reads" do
        html = page_html("war_and_peace_656.html.gz").sub(%r{<script id="__NEXT_DATA__".*?</script>}m, "")

        facts = BookPage.parse(html: html, status: 200).facts

        assert_equal [656, "War and Peace", 1868, "9780192833983"],
          [facts.goodreads_book_id, facts.title, facts.original_publication_year, facts.isbn13]
        assert_equal [["Leo Tolstoy", "Author", true], ["Aylmer Maude", "Translator", false],
          ["Louise Maude", "Translator", false]], contributors(facts)
      end

      test "__NEXT_DATA__ that lost its contributors (a renamed field) falls back to the markup" do
        html = page_html("war_and_peace_656.html.gz")
          .gsub('"primaryContributorEdge"', '"renamedPrimaryEdge"').gsub('"secondaryContributorEdges"', '"renamedSecondaryEdges"')

        facts = BookPage.parse(html: html, status: 200).facts

        assert_equal [["Leo Tolstoy", "Author", true], ["Aylmer Maude", "Translator", false],
          ["Louise Maude", "Translator", false]], contributors(facts)
      end

      # Stored as found, such a page would be a permanent mismatch that parks
      # every edition naming its id.
      test "a book with no title or no contributors is unparseable, never found" do
        book = {"legacyId" => 7, "title" => "Quiet", "details" => {},
                "primaryContributorEdge" => {"node" => {"__ref" => "Contributor:1"}, "role" => "Author"}}
        pages = [book.except("primaryContributorEdge"), book.merge("title" => "", "titleComplete" => nil)].map do |variant|
          apollo = {"ROOT_QUERY" => {%(getBookByLegacyId({"legacyId":"7"})) => {"__ref" => "Book:1"}}, "Book:1" => variant,
                    "Contributor:1" => {"name" => "Lei Xu"}}
          %(<script id="__NEXT_DATA__" type="application/json">#{{props: {pageProps: {apolloState: apollo}}}.to_json}</script>)
        end

        assert_equal [:unparseable, :unparseable], pages.map { |html| BookPage.parse(html: html, status: 200).outcome }
      end

      test "an unknown id is not found even though Goodreads answers 200" do
        parsed = BookPage.parse(html: page_html("not_found_99999999999.html.gz"), status: 200)

        assert_equal [:not_found, nil], [parsed.outcome, parsed.facts]
      end

      test "a 404 or 410 is not found" do
        assert_equal [:not_found, :not_found], [404, 410].map { |status| BookPage.parse(html: "", status: status).outcome }
      end

      test "Goodreads' own error page is unavailable, not an answer, whatever its status" do
        html = page_html("unexpected_error_503.html")

        assert_equal [:unavailable, :unavailable], [503, 200].map { |status| BookPage.parse(html: html, status: status).outcome }
      end

      test "a 401, 403 or 429 is blocked" do
        html = page_html("synthetic_challenge.html")

        assert_equal [:blocked] * 3, [401, 403, 429].map { |status| BookPage.parse(html: html, status: status).outcome }
      end

      test "a page it cannot recognize is unparseable" do
        pages = [page_html("synthetic_challenge.html"), "", %(<script id="__NEXT_DATA__">{not json</script>)]

        assert_equal [:unparseable] * 3, pages.map { |html| BookPage.parse(html: html, status: 200).outcome }
      end

      # Measured once from the fixture's description with tags stripped: 493
      # characters. A parser that kept markup, or lost text, falls outside 15%.
      STRAY_DESCRIPTION_LENGTH = 493

      test "a page names the description, genres, page count, format and main edition" do
        facts = BookPage.parse(html: page_html("catch_22_stray_edition_147719920.html.gz"), status: 200).facts

        assert_equal 147719920, facts.goodreads_book_id
        assert_predicate facts.description, :present?
        assert_not_includes facts.description, "<"
        assert_in_delta STRAY_DESCRIPTION_LENGTH, facts.description.length, STRAY_DESCRIPTION_LENGTH * 0.15
        assert_equal ["Classics", "Fiction", "Historical Fiction", "War", "Humor", "Literature", "Novels", "Satire", "Book Club", "Historical"], facts.genres
        assert_nil facts.page_count
        assert_equal ["Paperback", 168668], [facts.format, facts.best_book_id]
      end

      test "a page with a page count gives an integer, and a book gets genres" do
        facts = BookPage.parse(html: page_html("war_and_peace_656.html.gz"), status: 200).facts

        assert_predicate facts.genres, :any?
        assert_kind_of Integer, facts.page_count
        assert_equal 656, facts.best_book_id
      end

      test "the markup fallback has no description, genres, page count, format or main edition" do
        facts = BookPage.parse(html: page_html("no_next_data_129650.html.gz"), status: 200).facts

        assert_equal [nil, [], nil, nil, nil], [facts.description, facts.genres, facts.page_count, facts.format, facts.best_book_id]
      end

      test "a contributor with no role is unknown, every series is kept, and Goodreads' spacing is folded" do
        apollo = {
          "ROOT_QUERY" => {%(getBookByLegacyId({"legacyId":"7"})) => {"__ref" => "Book:1"}},
          "Book:1" => {"legacyId" => 7, "title" => "Quiet", "titleComplete" => "Quiet (Calm, #2)",
                       "primaryContributorEdge" => {"node" => {"__ref" => "Contributor:1"}, "role" => "Author"},
                       "secondaryContributorEdges" => [{"node" => {"__ref" => "Contributor:2"}, "role" => nil}],
                       "bookSeries" => [{"userPosition" => "2", "series" => {"__ref" => "Series:1"}},
                         {"userPosition" => "", "series" => {"__ref" => "Series:2"}}],
                       "details" => {}, "work" => {"__ref" => "Work:1"}},
          "Contributor:1" => {"name" => "Lei  Xu"},
          "Contributor:2" => {"name" => " Ana Ruiz "},
          "Series:1" => {"title" => "Calm", "webUrl" => "https://www.goodreads.com/series/41-calm"},
          "Series:2" => {"title" => "Quiet Books"},
          "Work:1" => {"details" => {"publicationTime" => nil}}
        }
        html = %(<script id="__NEXT_DATA__" type="application/json">#{{props: {pageProps: {apolloState: apollo}}}.to_json}</script>)

        facts = BookPage.parse(html: html, status: 200).facts

        assert_equal ["Quiet", nil], [facts.title, facts.original_publication_year]
        assert_equal [BookPage::Series.new(goodreads_series_id: 41, title: "Calm", position: "2"),
          BookPage::Series.new(goodreads_series_id: nil, title: "Quiet Books", position: nil)], facts.series
        assert_equal [["Lei Xu", "Author", true], ["Ana Ruiz", nil, false]], contributors(facts)
        assert_equal ["Lei Xu"], facts.contributors.select(&:creator?).map(&:name)
      end
    end
  end
end

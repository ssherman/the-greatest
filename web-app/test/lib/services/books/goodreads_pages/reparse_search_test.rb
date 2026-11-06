# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsPages
      class ReparseSearchTest < ActiveSupport::TestCase
        FETCHED_AT = Time.utc(2026, 11, 1, 2, 56)

        def stored(fixture: nil, version: 1, outcome: :unparseable)
          search = ::Books::GoodreadsSearch.create!(query: "catch-22", outcome: outcome, fetched_at: FETCHED_AT,
            http_status: 200, parser_version: version, rows: [])
          if fixture
            search.html.attach(io: StringIO.new(file_fixture("goodreads/searches/#{fixture}").binread),
              filename: "goodreads-search.html.gz", content_type: "application/gzip", identify: false)
          end
          search
        end

        test "an older unparseable search whose HTML now reads is stored as found, keeping when it was fetched" do
          search = stored(fixture: "jojo_redesign_2026_11.html.gz")

          result = ReparseSearch.call(search: search).reload

          assert_equal [:found, ::Books::Goodreads::SearchPage::VERSION, FETCHED_AT],
            [result.outcome.to_sym, result.parser_version, result.fetched_at]
          assert_equal [22545983, 7698607, 25398914], result.candidate_rows.map(&:goodreads_book_id)
        end

        test "a no-results page reads as no_results" do
          result = ReparseSearch.call(search: stored(fixture: "no_results_redesign_2026_11.html.gz")).reload

          assert_predicate result, :outcome_no_results?
        end

        test "HTML that still does not read stays unparseable at the current version, so it is not re-read again" do
          path = file_fixture("goodreads/searches/redesigned.html")
          search = stored
          search.html.attach(io: StringIO.new(Zlib.gzip(path.binread)), filename: "goodreads-search.html.gz",
            content_type: "application/gzip", identify: false)

          result = ReparseSearch.call(search: search).reload

          assert_equal [:unparseable, ::Books::Goodreads::SearchPage::VERSION], [result.outcome.to_sym, result.parser_version]
        end

        test "a search already at the current version is not re-read" do
          search = stored(fixture: "jojo_redesign_2026_11.html.gz", version: ::Books::Goodreads::SearchPage::VERSION)
          ::Books::Goodreads::SearchPage.expects(:parse).never

          assert_predicate ReparseSearch.call(search: search).reload, :outcome_unparseable?
        end

        test "a search with no HTML is returned unchanged" do
          result = ReparseSearch.call(search: stored).reload

          assert_equal [:unparseable, 1], [result.outcome.to_sym, result.parser_version]
        end

        test "a found search is left alone" do
          search = stored(fixture: "jojo_redesign_2026_11.html.gz", outcome: :found)
          ::Books::Goodreads::SearchPage.expects(:parse).never

          ReparseSearch.call(search: search)
        end
      end
    end
  end
end

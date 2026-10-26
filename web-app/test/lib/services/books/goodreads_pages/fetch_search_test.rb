# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsPages
      class FetchSearchTest < ActiveSupport::TestCase
        FETCHED_AT = Time.utc(2026, 10, 25, 12)

        def search_html(name)
          Zlib.gunzip(file_fixture("goodreads/searches/#{name}").binread).force_encoding(Encoding::UTF_8)
        end

        def fetched(html, status: 200)
          ::PageFetcher::Page.new(url: "u", final_url: "u", status: status, title: "t", html: html,
            selector_found: true, elapsed_ms: 5_000, fetched_at: FETCHED_AT)
        end

        def client_returning(page)
          stub("page_fetcher").tap { |client| client.stubs(:fetch).returns(page) }
        end

        def client_raising(error)
          stub("page_fetcher").tap { |client| client.stubs(:fetch).raises(error) }
        end

        test "a found search is stored with its rows, parser version and gzipped HTML" do
          html = search_html("catch_22_title_only.html.gz")
          client = mock("page_fetcher")
          client.expects(:fetch).with("https://www.goodreads.com/search?q=catch-22+joseph+heller", wait_for_selector: anything,
            timeout_ms: 30_000).returns(fetched(html))

          result = FetchSearch.call(query: "Catch-22 Joseph  Heller", client: client)

          search = result.data[:search]
          assert_equal [true, :found], [result.success?, result.data[:outcome]]
          assert_equal ["catch-22 joseph heller", "found", 200, 1, FETCHED_AT],
            [search.query, search.outcome, search.http_status, search.parser_version, search.fetched_at]
          assert_equal 168668, search.candidate_rows.first.goodreads_book_id
          assert_equal ["private_imports", "application/gzip"], [search.html.blob.service_name, search.html.blob.content_type]
          assert_equal html, Zlib.gunzip(search.html.download).force_encoding(Encoding::UTF_8)
        end

        test "a search with no results is stored as no_results" do
          result = FetchSearch.call(query: "zzqxjv wplkrtq", client: client_returning(fetched(search_html("no_results.html.gz"))))

          assert_equal [:no_results, []], [result.data[:outcome], result.data[:search].rows]
        end

        test "a blocked search is stored for a later look" do
          result = FetchSearch.call(query: "beloved", client: client_returning(fetched("", status: 403)))

          assert_equal [:blocked, "blocked"], [result.data[:outcome], result.data[:search].outcome]
        end

        test "a timeout stores nothing and is unavailable" do
          assert_no_difference("::Books::GoodreadsSearch.count") do
            result = FetchSearch.call(query: "beloved", client: client_raising(::PageFetcher::Exceptions::TimeoutError.new("timed out")))
            assert_equal [:unavailable, nil], result.data.values_at(:outcome, :search)
          end
        end

        test "Goodreads' error page (503) stores nothing and is unavailable" do
          assert_no_difference("::Books::GoodreadsSearch.count") do
            result = FetchSearch.call(query: "beloved", client: client_returning(fetched("", status: 503)))
            assert_equal :unavailable, result.data[:outcome]
          end
        end

        test "an open breaker is fetcher_down and stores nothing" do
          assert_no_difference("::Books::GoodreadsSearch.count") do
            result = FetchSearch.call(query: "beloved", client: client_raising(::PageFetcher::Exceptions::CircuitOpenError.new("open")))
            assert_equal :fetcher_down, result.data[:outcome]
          end
        end

        test "a second call for the same query updates the row in place" do
          FetchSearch.call(query: "beloved", client: client_returning(fetched("", status: 403)))

          assert_no_difference("::Books::GoodreadsSearch.count") do
            result = FetchSearch.call(query: " Beloved", client: client_returning(fetched(search_html("beloved_title_only.html.gz"))))
            assert_equal [:found, "found"], [result.data[:outcome], ::Books::GoodreadsSearch.find_by(query: "beloved").outcome]
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsPages
      class FetchPageTest < ActiveSupport::TestCase
        FETCHED_AT = Time.utc(2026, 10, 4, 12)

        def page_html(name)
          path = file_fixture("goodreads/pages/#{name}")
          html = name.end_with?(".gz") ? Zlib.gunzip(path.binread) : path.binread
          html.force_encoding(Encoding::UTF_8)
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

        test "a found page is stored with its facts and its gzipped HTML on the private service" do
          html = page_html("batman_writers_26067585.html.gz")
          client = mock("page_fetcher")
          client.expects(:fetch).with("https://www.goodreads.com/book/show/26067585", wait_for_selector: "h1", timeout_ms: 30_000)
            .returns(fetched(html))

          result = FetchPage.call(goodreads_book_id: 26067585, client: client)

          page = result.data[:page]
          assert_equal :found, result.data[:outcome]
          assert_equal ["fetched", "found", 200, 2, FETCHED_AT], [page.source, page.outcome, page.http_status, page.parser_version, page.fetched_at]
          assert_equal ["Batman, Volume 8: Superheavy", "9781401259693"], [page.title, page.isbn13]
          assert_equal [{"goodreads_series_id" => 130291, "title" => "Batman (2011)", "position" => nil}], page.series
          assert_equal({"name" => "Scott Snyder", "role" => "Writer", "primary" => true}, page.authors.first)
          assert_equal ["private_imports", "application/gzip"], [page.html.blob.service_name, page.html.blob.content_type]
          assert_equal html, Zlib.gunzip(page.html.download).force_encoding(Encoding::UTF_8)
        end

        test "an unknown id is stored as not found" do
          result = FetchPage.call(goodreads_book_id: 99_999_999_998, client: client_returning(fetched(page_html("not_found_99999999999.html.gz"))))

          page = result.data[:page]
          assert_equal [:not_found, true, nil, []], [result.data[:outcome], page.outcome_not_found?, page.title, page.authors]
        end

        test "Goodreads' error page stores nothing and is worth another try" do
          client = client_returning(fetched(page_html("unexpected_error_503.html"), status: 503))

          assert_no_difference("::Books::GoodreadsPage.count") do
            assert_equal [:unavailable, nil], FetchPage.call(goodreads_book_id: 327847, client: client).data.values_at(:outcome, :page)
          end
        end

        test "a challenge page is kept, HTML and all, and the next fetch replaces it" do
          blocked = FetchPage.call(goodreads_book_id: 26067585,
            client: client_returning(fetched(page_html("synthetic_challenge.html"), status: 403))).data[:page]
          html = page_html("batman_writers_26067585.html.gz")

          found = FetchPage.call(goodreads_book_id: 26067585, client: client_returning(fetched(html))).data[:page]

          assert_equal [blocked.id, "found"], [found.id, found.reload.outcome]
          assert_equal html, Zlib.gunzip(found.html.download).force_encoding(Encoding::UTF_8)
        end

        test "a page already answered is never overwritten" do
          client = client_returning(fetched(page_html("not_found_99999999999.html.gz")))

          result = FetchPage.call(goodreads_book_id: 656, client: client)

          assert_equal [:found, "War and Peace"], [result.data[:outcome], books_goodreads_pages(:war_and_peace_page).reload.title]
        end

        test "a found page stores the enrichment columns under parser version 2" do
          result = FetchPage.call(goodreads_book_id: 147719920,
            client: client_returning(fetched(page_html("catch_22_stray_edition_147719920.html.gz"))))

          page = result.data[:page]
          assert_equal [2, "Paperback", 168668, nil], [page.parser_version, page.format, page.best_book_id, page.page_count]
          assert_includes page.genres, "Satire"
          assert_predicate page.description, :present?
        end

        test "refresh fills the enrichment columns and HTML of a found legacy row and keeps what the import verified" do
          legacy = ::Books::GoodreadsPage.create!(goodreads_book_id: 26067585, source: :legacy, outcome: :found,
            fetched_at: Time.utc(2025, 1, 1), parser_version: nil, title: "Legacy Title", isbn13: "9780000000002",
            authors: [{"name" => "Legacy Author", "role" => "Author", "primary" => true}])
          html = page_html("batman_writers_26067585.html.gz")

          result = FetchPage.call(goodreads_book_id: 26067585, client: client_returning(fetched(html)), refresh: true)

          page = result.data[:page].reload
          assert_equal [:found, legacy.id], [result.data[:outcome], page.id]
          assert_equal ["legacy", "found", "Legacy Title", "9780000000002", [{"name" => "Legacy Author", "role" => "Author", "primary" => true}]],
            [page.source, page.outcome, page.title, page.isbn13, page.authors]
          assert_equal 2, page.parser_version
          assert_predicate page.genres, :any?
          assert_equal html, Zlib.gunzip(page.html.download).force_encoding(Encoding::UTF_8)
        end

        test "refresh never turns a found page into not found" do
          page = books_goodreads_pages(:war_and_peace_page)

          result = FetchPage.call(goodreads_book_id: 656, refresh: true,
            client: client_returning(fetched(page_html("not_found_99999999999.html.gz"))))

          page.reload
          assert_equal [:found, "found", 1, false], [result.data[:outcome], page.outcome, page.parser_version, page.html.attached?]
        end

        test "without refresh a found page is not refetched" do
          client = mock("page_fetcher")
          client.stubs(:fetch).returns(fetched(page_html("war_and_peace_656.html.gz")))

          FetchPage.call(goodreads_book_id: 656, client: client)

          assert_equal [1, false], [books_goodreads_pages(:war_and_peace_page).reload.parser_version, books_goodreads_pages(:war_and_peace_page).html.attached?]
        end

        test "a fetcher that cannot fetch stores nothing and says so; a timeout is worth another try" do
          cases = {
            ::PageFetcher::Exceptions::CircuitOpenError.new("open") => :fetcher_down,
            ::PageFetcher::Exceptions::ConfigurationError.new("no url") => :fetcher_down,
            ::PageFetcher::Exceptions::ClientError.new("invalid_url", 400) => :fetcher_down,
            ::PageFetcher::Exceptions::TimeoutError.new("slow") => :unavailable,
            ::PageFetcher::Exceptions::UpstreamError.new("upstream_unreachable", 502) => :unavailable
          }

          assert_no_difference("::Books::GoodreadsPage.count") do
            cases.each do |error, outcome|
              assert_equal outcome, FetchPage.call(goodreads_book_id: 1, client: client_raising(error)).data[:outcome], error.class.name
            end
          end
        end
      end
    end
  end
end

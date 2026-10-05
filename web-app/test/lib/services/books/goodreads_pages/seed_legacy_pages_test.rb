# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsPages
      class SeedLegacyPagesTest < ActiveSupport::TestCase
        LOOKED_UP = Time.utc(2025, 1, 2, 3, 4, 5)

        def legacy(goodreads_id:, title:, authors:, series: nil, isbn13: nil, isbn: nil, asin: nil,
          original_publication_year: nil, last_looked_up_at: nil, last_refreshed_at: LOOKED_UP)
          stub(goodreads_id: goodreads_id, title: title, authors: authors, series: series, isbn13: isbn13, isbn: isbn,
            asin: asin, original_publication_year: original_publication_year, last_looked_up_at: last_looked_up_at,
            last_refreshed_at: last_refreshed_at)
        end

        def seed(*records) = SeedLegacyPages.call(records: records).data

        test "a page-lookup row becomes a found legacy page, every name without a role" do
          seed(legacy(goodreads_id: "335131", title: "The Vile Village", authors: ["Lemony Snicket", "Brett Helquist"],
            series: "A Series of Unfortunate Events #7", isbn13: "9780192833983", asin: "B0001", original_publication_year: 2001,
            last_looked_up_at: LOOKED_UP + 1.day))

          page = ::Books::GoodreadsPage.find_by!(goodreads_book_id: 335131)
          assert_equal ["legacy", "found", LOOKED_UP + 1.day, nil, nil], [page.source, page.outcome, page.fetched_at, page.http_status, page.parser_version]
          assert_equal ["The Vile Village", 2001], [page.title, page.original_publication_year]
          assert_equal [{"goodreads_series_id" => nil, "title" => "A Series of Unfortunate Events", "position" => "7"}], page.series
          assert_equal ["9780192833983", "0192833987", "B0001"], [page.isbn13, page.isbn10, page.asin]
          assert_equal [{"name" => "Lemony Snicket", "role" => nil, "primary" => false},
            {"name" => "Brett Helquist", "role" => nil, "primary" => false}], page.authors
          assert_not page.html.attached?
        end

        test "a search-result row's series comes off its title" do
          seed(legacy(goodreads_id: "28854", title: "The Book of Lost Tales, Part Two (The History of Middle-earth, #2)",
            authors: ["J.R.R. Tolkien"]))

          page = ::Books::GoodreadsPage.find_by!(goodreads_book_id: 28854)
          assert_equal "The Book of Lost Tales, Part Two", page.title
          assert_equal [{"goodreads_series_id" => nil, "title" => "The History of Middle-earth", "position" => "2"}], page.series
        end

        test "names are folded and duplicates dropped" do
          seed(legacy(goodreads_id: "54976984", title: "The Coldest Case", authors: ["Martin  Walker", "Martin Walker"]))

          assert_equal ["Martin Walker"], ::Books::GoodreadsPage.find_by!(goodreads_book_id: 54976984).authors.map { |author| author["name"] }
        end

        test "rows it cannot use are skipped and counted" do
          counts = seed(legacy(goodreads_id: "not-an-id", title: "X", authors: ["A"]),
            legacy(goodreads_id: "1001", title: " ", authors: ["A"]),
            legacy(goodreads_id: "1002", title: "Y", authors: []))

          assert_equal({inserted: 0, already_present: 0, skipped: 3}, counts)
        end

        test "an id already cached is never overwritten, and a second run inserts nothing" do
          rows = [legacy(goodreads_id: "656", title: "Something Else", authors: ["Nobody"]),
            legacy(goodreads_id: "28854", title: "The Book of Lost Tales", authors: ["J.R.R. Tolkien"])]

          assert_equal({inserted: 1, already_present: 1, skipped: 0}, seed(*rows))
          assert_equal({inserted: 0, already_present: 2, skipped: 0}, seed(*rows))
          assert_equal "War and Peace", books_goodreads_pages(:war_and_peace_page).reload.title
        end

        test "two legacy rows for one id insert one page" do
          counts = seed(legacy(goodreads_id: "12345", title: "One", authors: ["A"]),
            legacy(goodreads_id: "12345.One_Title", title: "One", authors: ["A"]))

          assert_equal({inserted: 1, already_present: 1, skipped: 0}, counts)
        end
      end
    end
  end
end

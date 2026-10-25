# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsPages
      class ReparseTest < ActiveSupport::TestCase
        def stray_html
          Zlib.gunzip(file_fixture("goodreads/pages/catch_22_stray_edition_147719920.html.gz").binread)
        end

        def page_at_version(version, html: nil)
          page = ::Books::GoodreadsPage.create!(goodreads_book_id: 147719920, source: :fetched, outcome: :found,
            fetched_at: Time.utc(2026, 10, 4), parser_version: version, title: "Catch-22")
          if html
            page.html.attach(io: StringIO.new(Zlib.gzip(html)), filename: "p.html.gz", content_type: "application/gzip",
              identify: false, metadata: {analyzed: true})
          end
          page
        end

        test "a version 1 row with HTML gets the enrichment columns and the current version" do
          page = page_at_version(1, html: stray_html)

          result = Reparse.call(page: page).reload

          assert_equal [2, "Paperback", 168668, nil], [result.parser_version, result.format, result.best_book_id, result.page_count]
          assert_includes result.genres, "Satire"
          assert_predicate result.description, :present?
          assert_equal "Catch-22", result.title
        end

        test "a row with no HTML is returned unchanged" do
          page = page_at_version(1)

          result = Reparse.call(page: page).reload

          assert_equal [1, [], nil], [result.parser_version, result.genres, result.description]
        end

        test "a row already at the current version is returned untouched" do
          page = page_at_version(::Books::Goodreads::BookPage::VERSION, html: stray_html)

          result = Reparse.call(page: page).reload

          assert_equal [[], nil], [result.genres, result.description]
        end
      end
    end
  end
end

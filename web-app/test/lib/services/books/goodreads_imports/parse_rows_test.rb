# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ParseRowsTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        DUNE = {"Book Id" => "234225", "Title" => "Dune (Dune, #1)", "Author" => "Frank Herbert",
                "ISBN" => '="0441013597"', "Original Publication Year" => "1965", "Exclusive Shelf" => "read",
                "Private Notes" => "secret"}.freeze

        setup do
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :parsing)
        end

        test "writes a row per CSV row and an edition per Goodreads id and signature" do
          ParseRows.call(import: @import, rows: goodreads_rows(DUNE, DUNE.merge("Exclusive Shelf" => "to-read")))

          edition = ::Books::GoodreadsEdition.find_by!(goodreads_book_id: 234225)
          assert_equal [2, 1], [@import.reload.rows_count, @import.editions_count]
          assert_equal [edition.id, edition.id], @import.rows.order(:row_number).pluck(:goodreads_edition_id)
          assert_equal ["Dune", "Dune", "1", "Frank Herbert", "9780441013593", "0441013597", 1965],
            [edition.title, edition.series_name, edition.series_number, edition.primary_author, edition.isbn13,
              edition.isbn10, edition.original_publication_year]
        end

        test "a real Goodreads id under another title gets its own edition and leaves the honest one alone" do
          ParseRows.call(import: @import, rows: goodreads_rows(DUNE, DUNE.merge("Title" => "An Invented Book", "Author" => "Nobody")))

          editions = ::Books::GoodreadsEdition.where(goodreads_book_id: 234225).order(:id)
          assert_equal [["Dune", "Frank Herbert"], ["An Invented Book", "Nobody"]], editions.map { |e| [e.title, e.primary_author] }
        end

        test "a row that cannot be parsed is kept as failed, with why, and no edition" do
          ParseRows.call(import: @import, rows: goodreads_rows(DUNE.merge("Book Id" => "")))

          row = @import.rows.sole
          assert row.failed?
          assert_nil row.goodreads_edition_id
          assert_equal "no Goodreads book id", row.error
        end

        test "running it twice changes nothing" do
          rows = goodreads_rows(DUNE, DUNE.merge("Book Id" => "1", "Title" => "Other"))
          ParseRows.call(import: @import, rows: rows)

          assert_no_difference(["::Books::GoodreadsImportRow.count", "::Books::GoodreadsEdition.count"]) do
            ParseRows.call(import: @import, rows: rows)
          end
          assert_equal [2, 2], [@import.reload.rows_count, @import.editions_count]
        end

        test "an edition another import already parsed is reused, not rewritten" do
          other = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :complete)
          ParseRows.call(import: other, rows: goodreads_rows(DUNE))

          ParseRows.call(import: @import, rows: goodreads_rows(DUNE.merge("Original Publication Year" => "1999")))

          assert_equal 1, ::Books::GoodreadsEdition.where(goodreads_book_id: 234225).count
          assert_equal 1965, ::Books::GoodreadsEdition.find_by!(goodreads_book_id: 234225).original_publication_year
        end

        test "Private Notes is never stored; the parse notes are" do
          ParseRows.call(import: @import, rows: goodreads_rows(DUNE.merge("Date Read" => "someday")))

          row = @import.rows.sole
          assert_not row.raw.key?("Private Notes")
          assert_equal ["unreadable Date Read dropped: someday"], row.notes
        end
      end
    end
  end
end

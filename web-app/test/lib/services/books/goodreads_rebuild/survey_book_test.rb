# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class SurveyBookTest < ActiveSupport::TestCase
        setup do
          @import = books_goodreads_imports(:regular_user_import)
          @book = ::Books::Book.create!(title: "Tenth of December")
          @book.book_authors.create!(author: ::Books::Author.create!(name: "George Saunders"), position: 1)
          @row_number = 1_000
        end

        def edition(gr, title, author: "George Saunders", year: 2013)
          ::Books::GoodreadsEdition.create!(goodreads_book_id: gr, signature: "sig-#{gr}", title: title, primary_author: author,
            original_publication_year: year)
        end

        def row(edition, legacy_book_id: @book.id)
          ::Books::GoodreadsImportRow.create!(import: @import, row_number: (@row_number += 1), raw: {}, goodreads_edition: edition,
            legacy_book_id: legacy_book_id)
        end

        def survey(rows = ::Books::GoodreadsImportRow.where(legacy_book_id: @book.id).includes(:goodreads_edition).to_a)
          SurveyBook.call(book: @book, rows: rows).data[:survey]
        end

        test "a coherent book" do
          row(edition(1, "Tenth of December"))
          row(edition(2, "Zehnter Dezember"))

          result = survey

          assert_predicate result, :coherent?
          assert_equal [2, 2, 1], [result.edition_count, result.row_count, result.groups.size]
          assert result.title_agrees
          assert result.authors_agree
          refute result.wrong_book
        end

        test "a lump" do
          row(edition(1, "Tenth of December"))
          row(edition(2, "Lincoln in the Bardo", year: 2017))

          result = survey

          assert_predicate result, :lump?
          assert_equal 2, result.groups.size
        end

        test "a shared Open Library work makes a transliterated pair coherent" do
          leo = edition(1, "War and Peace", author: "Leo Tolstoy", year: 1869)
          lev = edition(2, "Voina i mir", author: "Lev Tolstoy", year: 1869)
          row(leo)
          row(lev)

          assert_predicate survey, :lump?

          [leo, lev].each do |e|
            ::Books::RebuildEditionEvidence.create!(goodreads_book_id: e.goodreads_book_id, signature: e.signature, world_cat: :no_record,
              ol_work_keys: ["OL267933W"], checked_at: Time.current)
          end

          assert_predicate survey, :coherent?
        end

        test "no rows is unsupported" do
          result = survey([])

          assert_predicate result, :unsupported?
          assert_equal 0, result.row_count
          assert_equal [nil, nil, false], [result.title_agrees, result.authors_agree, result.wrong_book]
        end

        test "a row with no edition is not counted" do
          row(edition(1, "Tenth of December"))
          ::Books::GoodreadsImportRow.create!(import: @import, row_number: 999, raw: {}, legacy_book_id: @book.id)

          assert_equal 1, survey.row_count
        end

        test "re-surveying updates the row in place" do
          row(edition(1, "Tenth of December"))
          first = survey
          travel 1.hour do
            second = survey

            assert_equal first.id, second.id
            assert_operator second.surveyed_at, :>, first.surveyed_at
          end
          assert_equal 1, ::Books::RebuildBookSurvey.where(book: @book).count
        end
      end

      class LegacyBookMapTest < ActiveSupport::TestCase
        setup do
          @import = books_goodreads_imports(:regular_user_import)
          @book = ::Books::Book.create!(title: "Survivor")
        end

        def row(legacy_book_id, number)
          ::Books::GoodreadsImportRow.create!(import: @import, row_number: 2_000 + number, raw: {}, legacy_book_id: legacy_book_id)
        end

        test "the map follows a merged-away legacy book" do
          row(999_999, 1)
          row(@book.id, 2)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(999_999).returns(@book)

          map = LegacyBookMap.build

          assert_equal [@book.id, 999_999].sort, map.legacy_ids_for(@book.id)
          assert_equal [@book.id, 999_999].sort, map.all_legacy_ids_for([@book.id]).sort
        end

        test "a vanished id that resolves to nothing is dropped" do
          row(999_998, 1)
          ::Services::Books::GoodreadsReplay::Apply::MergedBook.stubs(:call).with(999_998).returns(nil)

          assert_equal [@book.id], LegacyBookMap.build.legacy_ids_for(@book.id)
        end
      end
    end
  end
end

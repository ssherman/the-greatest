# frozen_string_literal: true

require "test_helper"

module Services
  module Identifiers
    class MarkLegacyTest < ActiveSupport::TestCase
      test "marks every unmarked books-domain row legacy and leaves music alone" do
        book_row = identifiers(:war_and_peace_isbn13)
        music_row = identifiers(:david_bowie_musicbrainz)

        result = MarkLegacy.call

        assert result.success?
        assert book_row.reload.source_legacy?
        assert_nil music_row.reload.source
        assert_operator result.data[:legacy], :>=, 1
      end

      test "marks author and edition rows too" do
        author_row = Identifier.create!(identifiable: books_authors(:tolstoy), identifier_type: :books_author_viaf, value: "1")
        edition_row = Identifier.create!(identifiable: books_editions(:wp_maude), identifier_type: :books_edition_isbn13, value: "9780000000017")

        MarkLegacy.call

        assert author_row.reload.source_legacy?
        assert edition_row.reload.source_legacy?
      end

      test "counts what it marked per identifiable type" do
        Identifier.create!(identifiable: books_authors(:tolstoy), identifier_type: :books_author_viaf, value: "1")
        expected = Identifier.where(identifiable_type: Identifier::BOOKS_TYPES, source: nil).group(:identifiable_type).count

        result = MarkLegacy.call

        assert_equal expected, result.data[:legacy_by_type]
        assert_equal expected.values.sum, result.data[:legacy]
      end

      test "never touches a row that already has a source" do
        row = Identifier.create!(identifiable: books_books(:war_and_peace), identifier_type: :books_work_oclc_id,
          value: "99", source: :worldcat)

        MarkLegacy.call

        assert row.reload.source_worldcat?
      end

      test "is safe to re-run" do
        MarkLegacy.call
        second = MarkLegacy.call

        assert_equal 0, second.data[:legacy]
      end

      test "batches cover every row" do
        result = MarkLegacy.call(batch_size: 2)

        assert_equal 0, Identifier.where(identifiable_type: Identifier::BOOKS_TYPES, source: nil).count
        assert_operator result.data[:legacy], :>, 2
      end

      test "relabels the keys the OL key backfill wrote or confirmed as open_library" do
        book = books_books(:crime_and_punishment)
        author = books_authors(:tolstoy)
        Identifier.create!(identifiable: book, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL9W")
        Identifier.create!(identifiable: author, identifier_type: :books_author_openlibrary_id, value: "OL1A")
        ::Books::OpenLibraryBackfill.create!(book: book, outcome: :confirmed, new_key: "OL262758W", old_keys: ["OL262758W"],
          duplicate_keys: ["OL9W"], author_changes: {"added" => [[author.id, "OL1A"]]}, run_id: "test")

        result = MarkLegacy.call

        assert Identifier.find_by!(identifiable: book, identifier_type: :books_work_openlibrary_id, value: "OL262758W").source_open_library?
        assert Identifier.find_by!(identifiable: book, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL9W").source_open_library?
        assert Identifier.find_by!(identifiable: author, identifier_type: :books_author_openlibrary_id, value: "OL1A").source_open_library?
        assert_equal 3, result.data[:open_library]
      end

      test "a reverted backfill row relabels nothing" do
        ::Books::OpenLibraryBackfill.create!(book: books_books(:crime_and_punishment), outcome: :reverted, new_key: "OL262758W",
          old_keys: [], run_id: "test")

        MarkLegacy.call

        assert identifiers(:crime_and_punishment_openlibrary).reload.source_legacy?
      end
    end
  end
end

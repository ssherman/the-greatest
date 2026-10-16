# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class RevertTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @tolstoy = books_authors(:tolstoy)
        end

        def keys(type) = @book.identifiers.where(identifier_type: type).order(:value).pluck(:value)

        test "a replaced book gets its old keys back; the new key, duplicates and author keys it added go" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W")
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::DUPLICATE_KEY, value: "OL2W")
          ::Identifier.create!(identifiable: @tolstoy, identifier_type: :books_author_openlibrary_id, value: "OL26783A")
          row = ::Books::Verification.create!(book: @book, work_outcome: :replaced, run_id: "run-1", old_keys: ["OL5W", "OL9W"],
            new_key: "OL1W", duplicate_keys: ["OL2W"], author_changes: {"added" => [[@tolstoy.id, "OL26783A"]], "pairs" => [], "conflicts" => []})

          result = Revert.call(book: @book)

          assert result.success?
          assert_equal [["OL5W", "OL9W"], [], "reverted"], [keys(ApplyBook::WORK_KEY), keys(ApplyBook::DUPLICATE_KEY), row.reload.work_outcome]
          assert_empty @tolstoy.identifiers.where(identifier_type: :books_author_openlibrary_id)
        end

        test "provenance: restored old keys come back legacy" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W", source: :open_library)
          ::Books::Verification.create!(book: @book, work_outcome: :replaced, run_id: "run-1", old_keys: ["OL5W"], new_key: "OL1W")

          Revert.call(book: @book)

          assert_equal [["OL5W", "legacy"]], @book.identifiers.where(identifier_type: ApplyBook::WORK_KEY).pluck(:value, :source)
        end

        test "provenance: a confirmed book's key goes back to legacy" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W", source: :open_library)
          ::Books::Verification.create!(book: @book, work_outcome: :confirmed, run_id: "run-1", old_keys: ["OL1W"], new_key: "OL1W")

          Revert.call(book: @book)

          assert_equal [["OL1W", "legacy"]], @book.identifiers.where(identifier_type: ApplyBook::WORK_KEY).pluck(:value, :source)
        end

        test "a replaced book that kept its old key as a duplicate key gets it back as the work key, with no duplicate left" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W")
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::DUPLICATE_KEY, value: "OL5W")
          ::Books::Verification.create!(book: @book, work_outcome: :replaced, run_id: "run-1", old_keys: ["OL5W"], new_key: "OL1W", duplicate_keys: ["OL5W"])

          Revert.call(book: @book)

          assert_equal [["OL5W"], []], [keys(ApplyBook::WORK_KEY), keys(ApplyBook::DUPLICATE_KEY)]
        end

        test "a work key added after the backfill survives; the new key goes and old keys return" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W")
          ::Books::Verification.create!(book: @book, work_outcome: :replaced, run_id: "run-1", old_keys: ["OL5W"], new_key: "OL1W")
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL7W")

          Revert.call(book: @book)

          assert_equal ["OL5W", "OL7W"], keys(ApplyBook::WORK_KEY)
        end

        test "a confirmed row whose new key is an old key leaves the book holding all its old keys" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W")
          ::Books::Verification.create!(book: @book, work_outcome: :confirmed, run_id: "run-1", old_keys: ["OL1W", "OL5W"], new_key: "OL1W")

          Revert.call(book: @book)

          assert_equal ["OL1W", "OL5W"], keys(ApplyBook::WORK_KEY)
        end

        test "a keyed book loses the key it was given" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::WORK_KEY, value: "OL1W")
          ::Books::Verification.create!(book: @book, work_outcome: :keyed, run_id: "run-1", old_keys: [], new_key: "OL1W")

          Revert.call(book: @book)

          assert_empty keys(ApplyBook::WORK_KEY)
        end

        test "a duplicate key the book had before the backfill stays" do
          ::Identifier.create!(identifiable: @book, identifier_type: ApplyBook::DUPLICATE_KEY, value: "OL3W")
          ::Books::Verification.create!(book: @book, work_outcome: :keyed, run_id: "run-1", new_key: "OL1W", duplicate_keys: [])

          Revert.call(book: @book)

          assert_equal ["OL3W"], keys(ApplyBook::DUPLICATE_KEY)
        end

        test "a removed book gets its old keys back" do
          ::Books::Verification.create!(book: @book, work_outcome: :removed, run_id: "run-1", old_keys: ["OL5W", "OL6W"])

          result = Revert.call(book: @book)

          assert result.success?
          assert_equal [["OL5W", "OL6W"], "reverted"], [keys(ApplyBook::WORK_KEY), ::Books::Verification.find_by!(book: @book).work_outcome]
        end

        test "revert removes what the pass added, restores what it confirmed, and drops findings and candidates" do
          row = ::Books::Verification.create!(book: @book, work_outcome: :unsure, run_id: "r", stage: :done)
          added = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "77", source: :worldcat)
          confirmed = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780307266934", source: :worldcat)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :added, identifier_type: :books_work_oclc_id, value: "77", identifier_id: added.id)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :confirmed, identifier_type: :books_work_isbn13,
            value: "9780307266934", identifier_id: confirmed.id, previous_source: :legacy)
          ::Books::EditionCandidate.create!(book: @book, edition_key: "OL2M")

          result = Revert.call(book: @book)

          assert result.success?
          assert_not ::Identifier.exists?(added.id)
          assert confirmed.reload.source_legacy?
          assert_empty row.reload.findings
          assert_equal 0, ::Books::EditionCandidate.where(book: @book).count
          assert row.reverted?
          assert_equal 0, result.data[:skipped]
        end

        test "an identifier the pass added that has since moved or gone is skipped and counted" do
          row = ::Books::Verification.create!(book: @book, work_outcome: :unsure, run_id: "r", stage: :done)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :added, identifier_type: :books_work_oclc_id, value: "77", identifier_id: 999_999_999)

          result = Revert.call(book: @book)

          assert result.success?
          assert_equal 1, result.data[:skipped]
        end

        test "a failed row cannot be reverted" do
          ::Books::Verification.create!(book: @book, work_outcome: :failed, run_id: "run-1")

          result = Revert.call(book: @book)

          assert_not result.success?
          assert_match(/failed/, result.errors.first)
          assert_not Revert.call(book: books_books(:got)).success?, "no row at all"
        end
      end
    end
  end
end

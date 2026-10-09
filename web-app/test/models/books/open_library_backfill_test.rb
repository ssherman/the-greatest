# frozen_string_literal: true

require "test_helper"

module Books
  class OpenLibraryBackfillTest < ActiveSupport::TestCase
    setup do
      @book = books_books(:war_and_peace)
    end

    test "outcome and lookup values are pinned" do
      assert_equal({"confirmed" => 0, "updated" => 1, "replaced" => 2, "keyed" => 3, "duplicate_pair" => 4,
                    "unsure" => 5, "failed" => 6, "reverted" => 7, "removed" => 8}, OpenLibraryBackfill.outcomes)
      assert_equal({"identifiers" => 0, "resolve" => 1}, OpenLibraryBackfill.lookups)
    end

    test "a row needs a book, an outcome and a run id" do
      row = OpenLibraryBackfill.new
      assert_not row.valid?
      assert_includes row.errors.attribute_names, :book
      assert_includes row.errors.attribute_names, :run_id
    end

    test "defaults: no keys, no author changes, one attempt" do
      row = OpenLibraryBackfill.create!(book: @book, outcome: :keyed, run_id: "run-1")
      assert_equal [[], [], {}, 1], [row.old_keys, row.duplicate_keys, row.author_changes, row.attempts]
    end

    test "one row per book, enforced by the database" do
      OpenLibraryBackfill.create!(book: @book, outcome: :keyed, run_id: "run-1")
      assert_raises(ActiveRecord::RecordNotUnique) { OpenLibraryBackfill.create!(book: @book, outcome: :unsure, run_id: "run-2") }
    end

    test "deleting the book deletes its row; deleting the pair book clears the pair" do
      other = books_books(:crime_and_punishment)
      row = OpenLibraryBackfill.create!(book: @book, outcome: :duplicate_pair, pair_book: other, run_id: "run-1")
      other.destroy!
      assert_nil row.reload.pair_book_id

      @book.destroy!
      assert_not OpenLibraryBackfill.exists?(row.id)
    end

    test "the new identifier type and duplicate source exist" do
      assert_equal 9, ::Identifier.identifier_types["books_work_openlibrary_duplicate_id"]
      assert_equal 5, ::DuplicateCandidate.sources["ol_backfill"]
    end
  end
end

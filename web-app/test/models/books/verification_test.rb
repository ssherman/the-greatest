# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: books_verifications
#
#  id                   :bigint           not null, primary key
#  attempts             :integer          default(1), not null
#  author_changes       :jsonb            not null
#  confirmed_on_abstain :boolean          default(FALSE), not null
#  dump_date            :string
#  duplicate_keys       :string           default([]), not null, is an Array
#  error                :text
#  lookup               :integer
#  matcher_version      :integer
#  new_key              :string
#  old_keys             :string           default([]), not null, is an Array
#  work_outcome         :integer          not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  book_id              :bigint           not null
#  pair_book_id         :bigint
#  run_id               :string           not null
#
# Indexes
#
#  index_books_verifications_on_book_id          (book_id) UNIQUE
#  index_books_verifications_on_work_outcome  (work_outcome)
#  index_books_verifications_on_run_id           (run_id)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => cascade
#  fk_rails_...  (pair_book_id => books_books.id) ON DELETE => nullify
#
module Books
  class VerificationTest < ActiveSupport::TestCase
    setup do
      @book = books_books(:war_and_peace)
    end

    test "outcome and lookup values are pinned" do
      assert_equal({"confirmed" => 0, "updated" => 1, "replaced" => 2, "keyed" => 3, "duplicate_pair" => 4,
                    "unsure" => 5, "failed" => 6, "reverted" => 7, "removed" => 8}, Verification.work_outcomes)
      assert_equal({"identifiers" => 0, "resolve" => 1, "resolve_candidate" => 2, "exact_title" => 3,
                    "held_key" => 4, "worldcat_isbns" => 5}, Verification.lookups)
    end

    test "a row needs a book, an outcome and a run id" do
      row = Verification.new
      assert_not row.valid?
      assert_includes row.errors.attribute_names, :book
      assert_includes row.errors.attribute_names, :run_id
    end

    test "defaults: no keys, no author changes, one attempt" do
      row = Verification.create!(book: @book, work_outcome: :keyed, run_id: "run-1")
      assert_equal [[], [], {}, 1], [row.old_keys, row.duplicate_keys, row.author_changes, row.attempts]
    end

    test "one row per book, enforced by the database" do
      Verification.create!(book: @book, work_outcome: :keyed, run_id: "run-1")
      assert_raises(ActiveRecord::RecordNotUnique) { Verification.create!(book: @book, work_outcome: :unsure, run_id: "run-2") }
    end

    test "deleting the book deletes its row; deleting the pair book clears the pair" do
      other = books_books(:crime_and_punishment)
      row = Verification.create!(book: @book, work_outcome: :duplicate_pair, pair_book: other, run_id: "run-1")
      other.destroy!
      assert_nil row.reload.pair_book_id

      @book.destroy!
      assert_not Verification.exists?(row.id)
    end

    test "cohort and stage default to pre_import and work" do
      row = ::Books::Verification.create!(book: books_books(:war_and_peace), work_outcome: :keyed, run_id: "r")

      assert row.cohort_pre_import?
      assert row.stage_work?
      assert_equal [0, 0, 0, 0, false], [row.added_count, row.confirmed_count, row.candidate_count, row.wrong_count, row.lump_suspect]
    end

    test "the new identifier type and duplicate source exist" do
      assert_equal 9, ::Identifier.identifier_types["books_work_openlibrary_duplicate_id"]
      assert_equal 5, ::DuplicateCandidate.sources["ol_backfill"]
    end

    test "the stage migration puts rows that predate it where their outcome says" do
      require Rails.root.join("db/migrate/20261016223421_add_stages_to_books_verifications.rb").to_s
      expected = {
        "confirmed" => "identifiers", "updated" => "identifiers", "replaced" => "identifiers", "keyed" => "identifiers",
        "duplicate_pair" => "worldcat", "unsure" => "worldcat", "removed" => "worldcat",
        "failed" => "work", "reverted" => "done"
      }
      books = ::Books::Book.limit(expected.size).to_a
      books << ::Books::Book.create!(title: "Backfill extra #{books.size}") while books.size < expected.size
      rows = expected.keys.zip(books).map do |outcome, book|
        row = ::Books::Verification.create!(book: book, work_outcome: outcome, run_id: "old", stage: :work)
        [row, outcome]
      end

      ::Books::Verification.connection.execute(AddStagesToBooksVerifications::BACKFILL_STAGE_SQL)

      assert_equal expected, rows.to_h { |row, outcome| [outcome, row.reload.stage] }
    end
  end
end

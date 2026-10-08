module Books
  # One row per book from the Open Library key backfill (spec
  # docs/superpowers/specs/2026-10-07-ol-key-backfill-design.md, section 3).
  # new_key is Open Library's answer; for a duplicate_pair it was not saved.
  class OpenLibraryBackfill < ApplicationRecord
    belongs_to :book, class_name: "Books::Book"
    belongs_to :pair_book, class_name: "Books::Book", optional: true

    enum :outcome, {confirmed: 0, updated: 1, replaced: 2, keyed: 3, duplicate_pair: 4, unsure: 5, failed: 6, reverted: 7}
    enum :lookup, {identifiers: 0, resolve: 1}, prefix: :via

    # Outcomes that leave the book with a key the backfill trusts.
    KEYED_OUTCOMES = %w[confirmed updated replaced keyed].freeze

    validates :outcome, :run_id, presence: true
  end
end

# == Schema Information
#
# Table name: books_open_library_backfills
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
#  outcome              :integer          not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  book_id              :bigint           not null
#  pair_book_id         :bigint
#  run_id               :string           not null
#
# Indexes
#
#  index_books_open_library_backfills_on_book_id  (book_id) UNIQUE
#  index_books_open_library_backfills_on_outcome  (outcome)
#  index_books_open_library_backfills_on_run_id   (run_id)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => cascade
#  fk_rails_...  (pair_book_id => books_books.id) ON DELETE => nullify
#
module Books
  # One row per book from the Open Library key backfill (spec
  # docs/superpowers/specs/2026-10-07-ol-key-backfill-design.md, section 3).
  # new_key is Open Library's answer; for a duplicate_pair it was not saved.
  class OpenLibraryBackfill < ApplicationRecord
    belongs_to :book, class_name: "Books::Book"
    belongs_to :pair_book, class_name: "Books::Book", optional: true

    enum :outcome, {confirmed: 0, updated: 1, replaced: 2, keyed: 3, duplicate_pair: 4, unsure: 5, failed: 6, reverted: 7, removed: 8}
    enum :lookup, {identifiers: 0, resolve: 1}, prefix: :via

    # Outcomes that leave the book with a key the backfill trusts.
    KEYED_OUTCOMES = %w[confirmed updated replaced keyed].freeze

    validates :outcome, :run_id, presence: true
  end
end

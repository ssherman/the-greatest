# == Schema Information
#
# Table name: books_goodreads_import_rows
#
#  id                   :bigint           not null, primary key
#  applied              :jsonb            not null
#  date_added           :date
#  date_read            :date
#  error                :text
#  exclusive_shelf      :string
#  notes                :string           default([]), not null, is an Array
#  outcome              :integer          default("pending"), not null
#  outcome_detail       :string
#  rating               :integer
#  raw                  :jsonb            not null
#  read_count           :integer
#  replay_finding       :integer
#  review_body          :text
#  row_number           :integer          not null
#  shelf_positions      :jsonb            not null
#  shelves              :string           default([]), not null, is an Array
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  goodreads_edition_id :bigint
#  import_id            :bigint           not null
#  legacy_book_id       :bigint
#
# Indexes
#
#  index_books_goodreads_import_rows_on_goodreads_edition_id      (goodreads_edition_id)
#  index_books_goodreads_import_rows_on_import_id_and_row_number  (import_id,row_number) UNIQUE
#  index_books_goodreads_import_rows_on_replay_finding            (replay_finding)
#
# Foreign Keys
#
#  fk_rails_...  (goodreads_edition_id => books_goodreads_editions.id)
#  fk_rails_...  (import_id => books_goodreads_imports.id) ON DELETE => cascade
#
module Books
  class GoodreadsImportRow < ApplicationRecord
    belongs_to :import, class_name: "Books::GoodreadsImport", inverse_of: :rows
    belongs_to :goodreads_edition, class_name: "Books::GoodreadsEdition", optional: true, inverse_of: :import_rows

    enum :outcome, {pending: 0, applied: 1, parked: 2, skipped: 3, failed: 4}
    # The legacy replay's comparison with the book legacy chose (spec §12.4).
    enum :replay_finding, {agrees: 0, duplicate: 1, disagrees: 2, unmatched: 3, no_legacy_choice: 4, awaiting_full_pass: 5},
      prefix: :replay

    # What the member's summary page says about a row (Goodreads import spec §11).
    MEMBER_STATUS_LABELS = {
      working: "Working on it",
      matched: "Matched",
      new_pending_review: "Added, waiting for review",
      flagged: "Matched, but we're not sure",
      not_found: "Not found on Goodreads",
      skipped: "Already on your lists",
      failed: "Couldn't import"
    }.freeze

    validates :row_number, presence: true, uniqueness: {scope: :import_id}
    validates :rating, inclusion: {in: 0..5}, allow_nil: true

    def member_status
      return :working if pending?
      return :not_found if parked?
      return :skipped if skipped?
      return :failed if failed?

      book = goodreads_edition&.book
      return :skipped if book.nil?
      return :new_pending_review if book.provisional?
      return :flagged if goodreads_edition.match_decision&.needs_review?

      :matched
    end
  end
end

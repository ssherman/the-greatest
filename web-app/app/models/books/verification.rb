# == Schema Information
#
# Table name: books_verifications
#
#  id                   :bigint           not null, primary key
#  added_count          :integer          default(0), not null
#  attempts             :integer          default(1), not null
#  author_changes       :jsonb            not null
#  candidate_count      :integer          default(0), not null
#  checked_at           :datetime
#  cohort               :integer          default("pre_import"), not null
#  confirmed_count      :integer          default(0), not null
#  confirmed_on_abstain :boolean          default(FALSE), not null
#  dump_date            :string
#  duplicate_keys       :string           default([]), not null, is an Array
#  error                :text
#  lookup               :integer
#  lump_suspect         :boolean          default(FALSE), not null
#  matcher_version      :integer
#  new_key              :string
#  old_keys             :string           default([]), not null, is an Array
#  stage                :integer          default("work"), not null
#  stage_error          :text
#  work_outcome         :integer          not null
#  worldcat_dump_date   :string
#  wrong_count          :integer          default(0), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  book_id              :bigint           not null
#  pair_book_id         :bigint
#  run_id               :string           not null
#
# Indexes
#
#  index_books_verifications_on_book_id       (book_id) UNIQUE
#  index_books_verifications_on_lump_suspect  (lump_suspect)
#  index_books_verifications_on_run_id        (run_id)
#  index_books_verifications_on_stage         (stage)
#  index_books_verifications_on_work_outcome  (work_outcome)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => cascade
#  fk_rails_...  (pair_book_id => books_books.id) ON DELETE => nullify
#
module Books
  # One row per book from the verification pass (spec docs/superpowers/specs/2026-10-16-book-verification-design.md,
  # section 3). Stage 1 is the OL key backfill (2026-10-07 spec).
  # new_key is Open Library's answer; for a duplicate_pair it was not saved.
  class Verification < ApplicationRecord
    belongs_to :book, class_name: "Books::Book"
    belongs_to :pair_book, class_name: "Books::Book", optional: true

    enum :work_outcome, {confirmed: 0, updated: 1, replaced: 2, keyed: 3, duplicate_pair: 4, unsure: 5, failed: 6, reverted: 7, removed: 8}
    enum :lookup, {identifiers: 0, resolve: 1}, prefix: :via
    has_many :findings, class_name: "Books::VerificationFinding", dependent: :delete_all

    # Spec section 4: pre_import books run by default; post_import ones only with the flag.
    enum :cohort, {pre_import: 0, post_import: 1}, prefix: true
    # The next stage to run (spec section 3). done: all four ran.
    enum :stage, {work: 0, identifiers: 1, worldcat: 2, signals: 3, done: 4}, prefix: true

    # Outcomes that leave the book with a key the verification pass trusts.
    KEYED_OUTCOMES = %w[confirmed updated replaced keyed].freeze

    # Work outcomes that settled a work whose editions stage 2 reads.
    SETTLED_FOR_EDITIONS = KEYED_OUTCOMES

    validates :work_outcome, :run_id, presence: true
  end
end

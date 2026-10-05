# == Schema Information
#
# Table name: books_goodreads_editions
#
#  id                        :bigint           not null, primary key
#  additional_authors        :string           default([]), not null, is an Array
#  book_format               :string
#  isbn10                    :string
#  isbn13                    :string
#  original_publication_year :integer
#  pages                     :integer
#  primary_author            :string           not null
#  publisher                 :string
#  resolution                :integer
#  resolved_at               :datetime
#  series_name               :string
#  series_number             :string
#  signature                 :string           not null
#  title                     :string           not null
#  verification              :integer          default("not_needed"), not null
#  year_published            :integer
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  book_id                   :bigint
#  goodreads_book_id         :bigint           not null
#  match_decision_id         :bigint
#  pending_import_id         :bigint
#
# Indexes
#
#  idx_on_goodreads_book_id_signature_8e389d2d73        (goodreads_book_id,signature) UNIQUE
#  index_books_goodreads_editions_on_book_id            (book_id)
#  index_books_goodreads_editions_on_match_decision_id  (match_decision_id)
#  index_books_goodreads_editions_on_pending_import_id  (pending_import_id)
#  index_books_goodreads_editions_on_signature          (signature)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => nullify
#  fk_rails_...  (match_decision_id => match_decisions.id) ON DELETE => nullify
#  fk_rails_...  (pending_import_id => books_goodreads_imports.id) ON DELETE => nullify
#
module Books
  # The unit an import resolves: one Goodreads id under one signature
  # (normalized title plus primary author), shared by every import and user
  # that names it. Resolved once; a later import reuses the answer while its
  # book exists (Goodreads import spec §3, §5).
  class GoodreadsEdition < ApplicationRecord
    belongs_to :book, class_name: "Books::Book", optional: true
    belongs_to :match_decision, optional: true
    # The import whose resolution waits on this edition's Goodreads page; it
    # owns what the page's answer creates.
    belongs_to :pending_import, class_name: "Books::GoodreadsImport", optional: true, inverse_of: :pending_editions
    has_many :import_rows, class_name: "Books::GoodreadsImportRow", inverse_of: :goodreads_edition,
      dependent: :restrict_with_exception

    enum :resolution, {matched: 0, created: 1, parked: 2}
    enum :verification, {not_needed: 0, pending: 1, verified: 2, not_found: 3, mismatch: 4, unverified: 5},
      prefix: true

    # Editions a Goodreads page settles: waiting to be created or parked, or
    # created before their page could be read. One whose created book was
    # since deleted is not among them: it goes back to the finder on the next
    # resolution, so a deletion sticks.
    scope :awaiting_goodreads, -> { verification_pending.or(created.verification_unverified.where.not(book_id: nil)) }

    validates :goodreads_book_id, :signature, :title, :primary_author, presence: true
    validates :signature, uniqueness: {scope: :goodreads_book_id}
  end
end

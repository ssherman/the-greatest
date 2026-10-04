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
#  verification              :integer          default(0), not null
#  year_published            :integer
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  book_id                   :bigint
#  goodreads_book_id         :bigint           not null
#  match_decision_id         :bigint
#
# Indexes
#
#  idx_on_goodreads_book_id_signature_8e389d2d73        (goodreads_book_id,signature) UNIQUE
#  index_books_goodreads_editions_on_book_id            (book_id)
#  index_books_goodreads_editions_on_match_decision_id  (match_decision_id)
#  index_books_goodreads_editions_on_signature          (signature)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => nullify
#  fk_rails_...  (match_decision_id => match_decisions.id) ON DELETE => nullify
#
module Books
  # The unit an import resolves: one Goodreads id under one signature
  # (normalized title plus primary author), shared by every import and user
  # that names it. Resolved once; a later import reuses the answer while its
  # book exists (Goodreads import spec §3, §5).
  class GoodreadsEdition < ApplicationRecord
    belongs_to :book, class_name: "Books::Book", optional: true
    belongs_to :match_decision, optional: true
    has_many :import_rows, class_name: "Books::GoodreadsImportRow", inverse_of: :goodreads_edition,
      dependent: :restrict_with_exception

    enum :resolution, {matched: 0, created: 1, parked: 2}
    enum :verification, {not_needed: 0, pending: 1, verified: 2, not_found: 3, mismatch: 4, unverified: 5},
      prefix: true

    validates :goodreads_book_id, :signature, :title, :primary_author, presence: true
    validates :signature, uniqueness: {scope: :goodreads_book_id}
  end
end

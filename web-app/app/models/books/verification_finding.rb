# == Schema Information
#
# Table name: books_verification_findings
#
#  id              :bigint           not null, primary key
#  evidence        :jsonb            not null
#  identifier_type :integer          not null
#  kind            :integer          not null
#  previous_source :integer
#  source          :integer
#  undo_action     :integer
#  undone_at       :datetime
#  value           :string           not null
#  work_key        :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  book_id         :bigint           not null
#  identifier_id   :bigint
#  other_book_id   :bigint
#  verification_id :bigint           not null
#
# Indexes
#
#  index_books_verification_findings_on_book_id          (book_id)
#  index_books_verification_findings_on_kind             (kind)
#  index_books_verification_findings_on_other_book_id    (other_book_id)
#  index_books_verification_findings_on_verification_id  (verification_id)
#  index_books_verification_findings_unique              (verification_id,kind,identifier_type,value) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => cascade
#  fk_rails_...  (other_book_id => books_books.id) ON DELETE => cascade
#  fk_rails_...  (verification_id => books_verifications.id) ON DELETE => cascade
#
module Books
  # One identifier the verification pass wrote, confirmed or flagged (spec section 3).
  class VerificationFinding < ApplicationRecord
    belongs_to :verification, class_name: "Books::Verification"
    belongs_to :book, class_name: "Books::Book"
    belongs_to :other_book, class_name: "Books::Book", optional: true

    enum :kind, {added: 0, confirmed: 1, conflict: 2, also_held: 3, wrong_identifier: 4, foreign_work: 5}
    enum :identifier_type, ::Identifier.identifier_types, prefix: :type
    enum :source, ::Identifier.sources, prefix: :source
    enum :previous_source, ::Identifier.sources, prefix: :previous

    # What undoing this finding did (Services::Books::AlternateTitles::UndoFindings).
    enum :undo_action, {identifier_destroyed: 0, source_restored: 1, identifier_gone: 2}, prefix: :undo
    scope :not_undone, -> { where(undone_at: nil) }

    validates :kind, :identifier_type, :value, presence: true
  end
end

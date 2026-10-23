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

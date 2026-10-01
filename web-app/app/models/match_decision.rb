class MatchDecision < ApplicationRecord
  # Associations
  belongs_to :record, polymorphic: true, optional: true
  belongs_to :subject, polymorphic: true, optional: true
  belongs_to :ai_chat, optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true
  has_many :duplicate_candidates, dependent: :nullify

  # Enums. `unmatched` is the spec's "new": an enum value `new` would define
  # a class-level scope that shadows MatchDecision.new.
  enum :outcome, {matched: 0, unmatched: 1}
  enum :confidence, {certain: 0, high: 1, medium: 2, low: 3}
  enum :decided_by, {identifier: 0, rule: 1, ai: 2, fallback: 3}, prefix: true

  # A person's verdict, set from the audit page. Only `rejected` is set today
  # (Services::Books::Authors::RejectExternalLink, spec §12).
  enum :verdict, {confirmed: 0, rejected: 1}, prefix: true

  # Validations
  validates :finder, presence: true

  # Scopes
  scope :needing_review, -> { where(needs_review: true, reviewed_at: nil) }
  scope :newest_first, -> { order(created_at: :desc) }
  scope :for_finder, ->(finder_class) { where(finder: finder_class.to_s) }

  def review!(by:, note: nil)
    update!(reviewed_at: Time.current, reviewed_by: by, review_note: note)
  end

  # The candidate snapshot this decision chose (selected_index counts from
  # one), or nil.
  def selected_candidate
    return nil unless selected_index&.positive?

    Array(candidates)[selected_index - 1]
  end
end

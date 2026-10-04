# == Schema Information
#
# Table name: match_decisions
#
#  id             :bigint           not null, primary key
#  candidates     :jsonb            not null
#  confidence     :integer          not null
#  decided_by     :integer          not null
#  finder         :string           not null
#  needs_review   :boolean          default(FALSE), not null
#  outcome        :integer          not null
#  query          :jsonb            not null
#  reason         :text
#  record_type    :string
#  review_note    :text
#  reviewed_at    :datetime
#  selected_index :integer
#  sources_failed :string           default([]), not null, is an Array
#  subject_type   :string
#  verdict        :integer
#  verify         :boolean          default(FALSE), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  ai_chat_id     :bigint
#  record_id      :bigint
#  reviewed_by_id :bigint
#  subject_id     :bigint
#
# Indexes
#
#  index_match_decisions_on_ai_chat_id                    (ai_chat_id)
#  index_match_decisions_on_created_at                    (created_at)
#  index_match_decisions_on_finder                        (finder)
#  index_match_decisions_on_needs_review_and_reviewed_at  (needs_review,reviewed_at)
#  index_match_decisions_on_record                        (record_type,record_id)
#  index_match_decisions_on_reviewed_by_id                (reviewed_by_id)
#  index_match_decisions_on_subject                       (subject_type,subject_id)
#
# Foreign Keys
#
#  fk_rails_...  (ai_chat_id => ai_chats.id) ON DELETE => nullify
#  fk_rails_...  (reviewed_by_id => users.id) ON DELETE => nullify
#
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

# One AI enrichment run on one record. The audit trail and the backlog: which
# model said what about which field, with what confidence, and whether it was
# applied. Skipped and failed runs get a row too.
# == Schema Information
#
# Table name: enrichments
#
#  id                :bigint           not null, primary key
#  citations         :jsonb            not null
#  confidence        :integer
#  enrichable_type   :string           not null
#  error             :text
#  facts             :jsonb            not null
#  kind              :string           not null
#  mode              :integer          default("knowledge"), not null
#  model             :string
#  outcome           :integer          not null
#  provider          :string
#  reason            :string
#  recognized        :boolean
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  ai_chat_id        :bigint
#  enrichable_id     :bigint           not null
#  match_decision_id :bigint
#
# Indexes
#
#  index_enrichments_on_ai_chat_id           (ai_chat_id)
#  index_enrichments_on_enrichable           (enrichable_type,enrichable_id)
#  index_enrichments_on_kind                 (kind)
#  index_enrichments_on_match_decision_id    (match_decision_id)
#  index_enrichments_on_mode_and_created_at  (mode,created_at)
#  index_enrichments_on_outcome              (outcome)
#
# Foreign Keys
#
#  fk_rails_...  (ai_chat_id => ai_chats.id) ON DELETE => nullify
#  fk_rails_...  (match_decision_id => match_decisions.id) ON DELETE => nullify
#
class Enrichment < ApplicationRecord
  KIND_FORMAT = /\A[a-z_]+\.[a-z_]+\z/

  belongs_to :enrichable, polymorphic: true
  belongs_to :ai_chat, optional: true
  belongs_to :match_decision, optional: true

  enum :mode, {knowledge: 0, research: 1}
  enum :outcome, {applied: 0, nothing_to_apply: 1, unrecognized: 2, skipped: 3, failed: 4}
  enum :confidence, {high: 0, medium: 1, low: 2}, prefix: true

  validates :kind, presence: true, format: {with: KIND_FORMAT}

  scope :for_kind, ->(kind) { where(kind: kind) }
  scope :today, -> { where(created_at: Time.current.beginning_of_day..) }
  scope :low_confidence_on, ->(fact) { where("facts -> ? ->> 'confidence' = 'low'", fact.to_s) }
end

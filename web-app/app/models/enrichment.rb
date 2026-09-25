# One AI enrichment run on one record. The audit trail and the backlog: which
# model said what about which field, with what confidence, and whether it was
# applied. Skipped and failed runs get a row too.
class Enrichment < ApplicationRecord
  KIND_FORMAT = /\A[a-z_]+\.[a-z_]+\z/

  belongs_to :enrichable, polymorphic: true
  belongs_to :ai_chat, optional: true

  enum :mode, {knowledge: 0, research: 1}
  enum :outcome, {applied: 0, nothing_to_apply: 1, unrecognized: 2, skipped: 3, failed: 4}
  enum :confidence, {high: 0, medium: 1, low: 2}, prefix: true

  validates :kind, presence: true, format: {with: KIND_FORMAT}

  scope :for_kind, ->(kind) { where(kind: kind) }
  scope :today, -> { where(created_at: Time.current.beginning_of_day..) }
  scope :low_confidence_on, ->(fact) { where("facts -> ? ->> 'confidence' = 'low'", fact.to_s) }
end

# == Schema Information
#
# Table name: enrichment_requests
#
#  id               :bigint           not null, primary key
#  answer           :jsonb
#  attempts         :integer          default(0), not null
#  enrichable_type  :string           not null
#  error            :text
#  fingerprint      :string
#  kind             :string           not null
#  lease_expires_at :datetime
#  lease_token      :string
#  note             :text
#  outcome          :string
#  priority         :integer          default(1000000), not null
#  reason           :string           not null
#  resolved_at      :datetime
#  resolved_via     :integer
#  sources          :jsonb            not null
#  status           :integer          default(0), not null
#  version          :integer          default(1), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  claimed_by_id    :bigint
#  enrichable_id    :bigint           not null
#  enrichment_id    :bigint
#  resolved_by_id   :bigint
#
# Indexes
#
#  idx_on_kind_status_priority_id_ac9b960249          (kind,status,priority,id)
#  index_enrichment_requests_on_claimed_by_id         (claimed_by_id)
#  index_enrichment_requests_on_enrichment_id         (enrichment_id)
#  index_enrichment_requests_on_resolved_by_id        (resolved_by_id)
#  index_enrichment_requests_one_per_record_and_kind  (enrichable_type,enrichable_id,kind) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (claimed_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (enrichment_id => enrichments.id) ON DELETE => nullify
#  fk_rails_...  (resolved_by_id => users.id) ON DELETE => nullify
#
# One queue row per record and enrichment type: the thing an AI agent claims,
# answers and closes through the admin API. The row says what is wanted and
# who holds it; it is not the history. The enrichments ledger holds every
# answer ever applied, and `enrichment` points at the one that closed this row.
class EnrichmentRequest < ApplicationRecord
  LEASE = 30.minutes
  MAX_ATTEMPTS = 3
  REASONS = %w[missing research_wanted changed version manual].freeze

  # "via" is uncountable, so the generated mapping is EnrichmentRequest.resolved_via.
  enum :status, {pending: 0, claimed: 1, submitted: 2, done: 3, skipped: 4, failed: 5}
  # Prefixed: an unprefixed :system would define EnrichmentRequest.system and shadow Kernel#system.
  enum :resolved_via, {api: 0, paid_research: 1, admin_ui: 2, system: 3}, prefix: :resolved_via

  # What a row gets when it is re-opened (Fill's version re-open, Requeue), apart
  # from reason and version, which the caller supplies. Defined once so the two
  # callers cannot drift apart.
  REOPEN_RESET = {
    status: statuses.fetch("pending"),
    attempts: 0,
    outcome: nil,
    note: nil,
    answer: nil,
    error: nil,
    sources: [],
    enrichment_id: nil,
    lease_token: nil,
    lease_expires_at: nil,
    claimed_by_id: nil,
    resolved_by_id: nil,
    resolved_via: nil,
    resolved_at: nil
  }.freeze

  belongs_to :enrichable, polymorphic: true
  belongs_to :enrichment, optional: true
  belongs_to :claimed_by, class_name: "User", optional: true
  belongs_to :resolved_by, class_name: "User", optional: true

  validates :kind, presence: true, format: {with: Enrichment::KIND_FORMAT}
  validates :reason, inclusion: {in: REASONS}

  scope :for_kind, ->(kind) { where(kind: kind) }
  scope :claimable, -> { pending.or(claimed.where(lease_expires_at: ...Time.current)) }
  scope :open, -> { where(status: [:pending, :claimed]) }
  scope :resolved, -> { where(status: [:done, :skipped]) }
end

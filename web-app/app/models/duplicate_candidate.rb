# == Schema Information
#
# Table name: duplicate_candidates
#
#  id                :bigint           not null, primary key
#  evidence          :jsonb            not null
#  item_type         :string           not null
#  occurrences       :integer          default(1), not null
#  resolution_note   :text
#  resolved_at       :datetime
#  source            :integer          not null
#  status            :integer          default("pending"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  item_a_id         :bigint           not null
#  item_b_id         :bigint           not null
#  match_decision_id :bigint
#  resolved_by_id    :bigint
#
# Indexes
#
#  index_duplicate_candidates_on_match_decision_id      (match_decision_id)
#  index_duplicate_candidates_on_pair                   (item_type,item_a_id,item_b_id) UNIQUE
#  index_duplicate_candidates_on_resolved_by_id         (resolved_by_id)
#  index_duplicate_candidates_on_status_and_created_at  (status,created_at)
#  index_duplicate_candidates_on_type_and_b             (item_type,item_b_id)
#
# Foreign Keys
#
#  fk_rails_...  (match_decision_id => match_decisions.id) ON DELETE => nullify
#  fk_rails_...  (resolved_by_id => users.id) ON DELETE => nullify
#
class DuplicateCandidate < ApplicationRecord
  # Associations
  belongs_to :match_decision, optional: true
  belongs_to :resolved_by, class_name: "User", optional: true

  # Enums. `pending` is the spec's "open".
  enum :source, {identifier_collision: 0, external_key_collision: 1, ai: 2, human: 3, bulk_verify: 4, ol_backfill: 5}, prefix: :raised_by
  enum :status, {pending: 0, merged: 1, not_duplicate: 2}

  # Validations
  validates :item_type, presence: true
  validates :item_a_id, :item_b_id, presence: true
  validates :item_b_id, uniqueness: {scope: [:item_type, :item_a_id]}
  validate :ids_in_order

  # Scopes
  scope :for_type, ->(item_type) { where(item_type: item_type) }
  scope :newest_first, -> { order(created_at: :desc) }

  def self.not_duplicate?(item_type:, ids:)
    a, b = ids.map(&:to_i).minmax
    where(item_type: item_type, item_a_id: a, item_b_id: b).not_duplicate.exists?
  end

  # The queue's badge. "OL" is an initialism, so humanize alone gets it wrong.
  def source_label
    (source == "ol_backfill") ? "OL backfill" : source.humanize
  end

  private

  def ids_in_order
    return if item_a_id.blank? || item_b_id.blank?

    errors.add(:item_b_id, "must be greater than item_a_id") unless item_a_id < item_b_id
  end
end

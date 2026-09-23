class DuplicateCandidate < ApplicationRecord
  # Associations
  belongs_to :match_decision, optional: true
  belongs_to :resolved_by, class_name: "User", optional: true

  # Enums. `pending` is the spec's "open".
  enum :source, {identifier_collision: 0, external_key_collision: 1, ai: 2, human: 3, bulk_verify: 4}, prefix: :raised_by
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

  private

  def ids_in_order
    return if item_a_id.blank? || item_b_id.blank?

    errors.add(:item_b_id, "must be greater than item_a_id") unless item_a_id < item_b_id
  end
end

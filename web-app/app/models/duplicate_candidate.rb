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

  # Raise (or re-raise) a suspected pair. Ids may arrive in any order. A pair
  # a human dismissed is never reopened, and a merged one is left alone; a
  # pending one gains an occurrence and any new evidence.
  def self.flag!(item_type:, ids:, source:, evidence: {}, match_decision: nil)
    a, b = ids.map(&:to_i).minmax
    return nil if a == b

    row = find_or_initialize_by(item_type: item_type, item_a_id: a, item_b_id: b)
    if row.persisted?
      return row unless row.pending?

      row.occurrences += 1
      row.evidence = merge_evidence(row.evidence, evidence)
      row.save!
      return row
    end

    row.assign_attributes(source: source, evidence: evidence.deep_stringify_keys, match_decision: match_decision, status: :pending, occurrences: 1)
    row.save!
    row
  end

  def self.not_duplicate?(item_type:, ids:)
    a, b = ids.map(&:to_i).minmax
    where(item_type: item_type, item_a_id: a, item_b_id: b).not_duplicate.exists?
  end

  # Called by every merger inside its transaction, before the source row is
  # destroyed. The (source, target) pair itself becomes `merged`; every other
  # PENDING pair naming the source is re-keyed onto the target unless a row
  # for that pair already exists, in which case the stale one is dropped.
  # Decisions whose record was the source now point at the target.
  def self.record_merge(item_type:, source_id:, target_id:)
    a, b = [source_id, target_id].minmax
    where(item_type: item_type, item_a_id: a, item_b_id: b)
      .update_all(status: statuses[:merged], resolved_at: Time.current, updated_at: Time.current)

    where(item_type: item_type, status: statuses[:pending])
      .where("item_a_id = :id OR item_b_id = :id", id: source_id)
      .find_each do |row|
        other = (row.item_a_id == source_id) ? row.item_b_id : row.item_a_id
        next row.destroy! if other == target_id

        new_a, new_b = [other, target_id].minmax
        if exists?(item_type: item_type, item_a_id: new_a, item_b_id: new_b)
          row.destroy!
        else
          row.update!(item_a_id: new_a, item_b_id: new_b)
        end
      end

    MatchDecision.where(record_type: item_type, record_id: source_id)
      .update_all(record_id: target_id, updated_at: Time.current)
  end

  def self.merge_evidence(existing, incoming)
    existing.merge(incoming.deep_stringify_keys) do |_key, old, new|
      (old.is_a?(Array) && new.is_a?(Array)) ? (old | new) : new
    end
  end
  private_class_method :merge_evidence

  private

  def ids_in_order
    return if item_a_id.blank? || item_b_id.blank?

    errors.add(:item_b_id, "must be greater than item_a_id") unless item_a_id < item_b_id
  end
end

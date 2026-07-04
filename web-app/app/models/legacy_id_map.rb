class LegacyIdMap < ApplicationRecord
  validates :model, presence: true
  validates :legacy_id, presence: true, uniqueness: {scope: :model}
  validates :new_id, presence: true

  def self.record(model:, legacy_id:, new_id:)
    now = Time.current
    upsert(
      {model: model, legacy_id: legacy_id, new_id: new_id, created_at: now, updated_at: now},
      unique_by: [:model, :legacy_id],
      update_only: [:new_id, :updated_at],
      record_timestamps: false
    )
    new_id
  end

  def self.lookup(model:, legacy_id:)
    where(model: model, legacy_id: legacy_id).pick(:new_id)
  end
end

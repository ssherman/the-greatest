class LegacyIdMap < ApplicationRecord
  validates :model, presence: true
  validates :legacy_id, presence: true, uniqueness: {scope: :model}
  validates :new_id, presence: true

  def self.record(model:, legacy_id:, new_id:)
    upsert(
      {model: model, legacy_id: legacy_id, new_id: new_id, created_at: Time.current, updated_at: Time.current},
      unique_by: [:model, :legacy_id]
    )
    new_id
  end

  def self.lookup(model:, legacy_id:)
    where(model: model, legacy_id: legacy_id).pick(:new_id)
  end
end

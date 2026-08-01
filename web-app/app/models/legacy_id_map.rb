# == Schema Information
#
# Table name: legacy_id_maps
#
#  id         :bigint           not null, primary key
#  model      :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  legacy_id  :bigint           not null
#  new_id     :bigint           not null
#
# Indexes
#
#  index_legacy_id_maps_on_model_and_legacy_id  (model,legacy_id) UNIQUE
#
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

# frozen_string_literal: true

# == Schema Information
#
# Table name: external_records
#
#  id             :bigint           not null, primary key
#  fetched_at     :datetime         not null
#  payload        :jsonb            not null
#  schema_version :integer          default(1), not null
#  source         :integer          not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  source_id      :string           not null
#
# Indexes
#
#  index_external_records_on_source_and_fetched_at  (source,fetched_at)
#  index_external_records_on_source_and_source_id   (source,source_id) UNIQUE
#
class ExternalRecord < ApplicationRecord
  enum :source, {viaf: 0}

  validates :source, presence: true
  validates :source_id, presence: true, uniqueness: {scope: :source}
  validates :fetched_at, presence: true
  validate :payload_must_be_present

  scope :stale, ->(cutoff) { where(fetched_at: ...cutoff) }

  private

  # A plain `presence: true` on a jsonb column treats an empty Hash as blank
  # (Hash#empty? => true), which would reject a legitimately empty payload.
  # Only a missing (nil) payload is invalid.
  def payload_must_be_present
    errors.add(:payload, :blank) if payload.nil?
  end
end

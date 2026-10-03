# frozen_string_literal: true

# == Schema Information
#
# Table name: external_records
#
#  id             :bigint           not null, primary key
#  fetched_at     :datetime         not null
#  payload        :jsonb            not null
#  raw            :binary
#  schema_version :integer          default(1), not null
#  source         :integer          not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  source_id      :string           not null
#
# Indexes
#
#  index_external_records_on_source_and_fetched_at         (source,fetched_at)
#  index_external_records_on_source_and_source_id          (source,source_id) UNIQUE
#  index_external_records_on_wikipedia_language_and_title  (((payload ->> 'language'::text)), ((payload ->> 'title'::text))) WHERE (source = 2)
#
class ExternalRecord < ApplicationRecord
  enum :source, {viaf: 0, wikidata: 1, wikipedia: 2}

  validates :source, presence: true
  validates :source_id, presence: true, uniqueness: {scope: :source}
  validates :fetched_at, presence: true
  validate :payload_must_be_present

  scope :stale, ->(cutoff) { where(fetched_at: ...cutoff) }

  # The complete response body, gzipped in `raw` (spec §3). `payload` stays
  # the small distilled view the code reads; this is kept so a later feature
  # can use more of a response without calling the API again.
  def raw_text
    raw && ActiveSupport::Gzip.decompress(raw).force_encoding(Encoding::UTF_8)
  end

  def raw_text=(text)
    self.raw = text && ActiveSupport::Gzip.compress(text)
  end

  private

  # A plain `presence: true` on a jsonb column treats an empty Hash as blank
  # (Hash#empty? => true), which would reject a legitimately empty payload.
  # Only a missing (nil) payload is invalid.
  def payload_must_be_present
    errors.add(:payload, :blank) if payload.nil?
  end
end

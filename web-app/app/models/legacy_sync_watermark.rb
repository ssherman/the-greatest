# The highest legacy id data_migration:sync has processed, per legacy table
# (spec 2026-10-08-books-legacy-sync §5). Written once by sync_init, advanced by
# each successful sync.
# == Schema Information
#
# Table name: legacy_sync_watermarks
#
#  id         :bigint           not null, primary key
#  key        :string           not null
#  value      :bigint           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_legacy_sync_watermarks_on_key  (key) UNIQUE
#
class LegacySyncWatermark < ApplicationRecord
  KEYS = %w[books authors book_identifiers].freeze

  validates :key, inclusion: {in: KEYS}, uniqueness: true
  validates :value, presence: true
end

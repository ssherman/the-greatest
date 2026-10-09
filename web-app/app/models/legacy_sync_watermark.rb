# The highest legacy id data_migration:sync has processed, per legacy table
# (spec 2026-10-08-books-legacy-sync §5). Written once by sync_init, advanced by
# each successful sync.
class LegacySyncWatermark < ApplicationRecord
  KEYS = %w[books authors book_identifiers].freeze

  validates :key, inclusion: {in: KEYS}, uniqueness: true
  validates :value, presence: true
end

# What became of a legacy-origin Books::Book or Books::Author that no longer
# exists here: merged into to_id, or deleted (to_id nil). The books legacy sync
# reads it so it never brings either back (spec 2026-10-08-books-legacy-sync §4).
class RecordRedirect < ApplicationRecord
  ITEM_TYPES = %w[Books::Book Books::Author].freeze

  validates :item_type, inclusion: {in: ITEM_TYPES}
  validates :from_id, presence: true, uniqueness: {scope: :item_type}
end

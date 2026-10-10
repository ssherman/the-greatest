# What became of a legacy-origin Books::Book or Books::Author that no longer
# exists here: merged into to_id, or deleted (to_id nil). The books legacy sync
# reads it so it never brings either back (spec 2026-10-08-books-legacy-sync §4).
# == Schema Information
#
# Table name: record_redirects
#
#  id         :bigint           not null, primary key
#  item_type  :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  from_id    :bigint           not null
#  to_id      :bigint
#
# Indexes
#
#  index_record_redirects_on_item_type_and_from_id  (item_type,from_id) UNIQUE
#
class RecordRedirect < ApplicationRecord
  ITEM_TYPES = %w[Books::Book Books::Author].freeze

  validates :item_type, inclusion: {in: ITEM_TYPES}
  validates :from_id, presence: true, uniqueness: {scope: :item_type}
end

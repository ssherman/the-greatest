# == Schema Information
#
# Table name: languages
#
#  id         :bigint           not null, primary key
#  iso_639_1  :string(2)
#  iso_639_3  :string(3)
#  name       :string           not null
#  slug       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_languages_on_iso_639_3  (iso_639_3) UNIQUE
#  index_languages_on_name       (name)
#  index_languages_on_slug       (slug) UNIQUE
#
class Language < ApplicationRecord
  extend FriendlyId
  friendly_id :name, use: [ :slugged, :finders ]

  validates :name, presence: true
  validates :iso_639_1, length: { is: 2 }, allow_blank: true
  validates :iso_639_3, length: { is: 3 }, allow_blank: true, uniqueness: { allow_nil: true }
end

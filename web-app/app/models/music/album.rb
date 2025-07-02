class Music::Album < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: [:slugged, :finders]

  # Associations
  belongs_to :primary_artist, class_name: "Music::Artist"
  # has_many :releases
  # has_many :songs, through: :releases
  # has_many :credits, as: :creditable

  # Validations
  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :primary_artist, presence: true
  validates :release_year, numericality: {only_integer: true, allow_nil: true}
end

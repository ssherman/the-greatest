class Music::Release < ApplicationRecord
  # Enums
  enum :format, {vinyl: 0, cd: 1, digital: 2, cassette: 3, blu_ray: 4}, prefix: true

  # Associations
  belongs_to :album, class_name: "Music::Album"
  # has_many :tracks, -> { order(:disc_number, :position) }
  # has_many :songs, through: :tracks
  # has_many :credits, as: :creditable

  # Validations
  validates :album, presence: true
  validates :format, presence: true

  # Scopes
  scope :by_format, ->(format) { where(format: format) }
  scope :released_before, ->(date) { where("release_date <= ?", date) }
  scope :released_after, ->(date) { where("release_date >= ?", date) }
end

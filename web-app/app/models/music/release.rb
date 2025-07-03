class Music::Release < ApplicationRecord
  # Enums
  enum :format, {vinyl: 0, cd: 1, digital: 2, cassette: 3, blu_ray: 4}, prefix: true

  # Associations
  belongs_to :album, class_name: "Music::Album"
  has_many :tracks, -> { order(:medium_number, :position) }, class_name: "Music::Track"
  has_many :songs, through: :tracks, class_name: "Music::Song"
  has_many :credits, as: :creditable, class_name: "Music::Credit"

  # Validations
  validates :album, presence: true
  validates :format, presence: true

  # Scopes
  scope :by_format, ->(format) { where(format: format) }
  scope :released_before, ->(date) { where("release_date <= ?", date) }
  scope :released_after, ->(date) { where("release_date >= ?", date) }
end

class Music::Song < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: [:slugged, :finders]

  # Associations
  has_many :tracks, class_name: "Music::Track"
  has_many :releases, through: :tracks, class_name: "Music::Release"
  has_many :albums, through: :releases, class_name: "Music::Album"
  # has_many :credits, as: :creditable
  # has_many :song_relationships
  # has_many :related_songs, through: :song_relationships, source: :related_song

  # Validations
  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :duration_secs, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
  validates :release_year, numericality: {only_integer: true, greater_than: 1900, less_than_or_equal_to: Date.current.year + 1}, allow_nil: true
  validates :isrc, length: {is: 12}, allow_blank: true
  validates :isrc, uniqueness: {allow_blank: true}

  # Scopes
  scope :with_lyrics, -> { where.not(lyrics: [nil, ""]) }
  scope :by_duration, ->(seconds) { where("duration_secs <= ?", seconds) }
  scope :longer_than, ->(seconds) { where("duration_secs > ?", seconds) }
  scope :released_in, ->(year) { where(release_year: year) }
  scope :released_before, ->(year) { where("release_year <= ?", year) }
  scope :released_after, ->(year) { where("release_year >= ?", year) }
end

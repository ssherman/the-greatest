class Music::Song < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: [:slugged, :finders]

  # Associations
  # has_many :tracks
  # has_many :releases, through: :tracks
  # has_many :albums, through: :releases
  # has_many :credits, as: :creditable
  # has_many :song_relationships
  # has_many :related_songs, through: :song_relationships, source: :related_song

  # Validations
  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :duration_secs, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
  validates :isrc, length: {is: 12}, allow_blank: true
  validates :isrc, uniqueness: {allow_blank: true}

  # Scopes
  scope :with_lyrics, -> { where.not(lyrics: [nil, ""]) }
  scope :by_duration, ->(seconds) { where("duration_secs <= ?", seconds) }
  scope :longer_than, ->(seconds) { where("duration_secs > ?", seconds) }
end

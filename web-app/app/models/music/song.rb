# == Schema Information
#
# Table name: music_songs
#
#  id            :bigint           not null, primary key
#  description   :text
#  duration_secs :integer
#  isrc          :string(12)
#  lyrics        :text
#  release_year  :integer
#  slug          :string           not null
#  title         :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_music_songs_on_isrc  (isrc) UNIQUE WHERE (isrc IS NOT NULL)
#  index_music_songs_on_slug  (slug) UNIQUE
#
class Music::Song < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: [:slugged, :finders]

  # Associations
  has_many :tracks, class_name: "Music::Track"
  has_many :releases, through: :tracks, class_name: "Music::Release"
  has_many :albums, through: :releases, class_name: "Music::Album"
  has_many :credits, as: :creditable, class_name: "Music::Credit"

  # Song relationships
  has_many :song_relationships, class_name: "Music::SongRelationship", foreign_key: :song_id, dependent: :destroy
  has_many :related_songs, through: :song_relationships, source: :related_song

  # Reverse relationships (e.g., songs that cover this song)
  has_many :inverse_song_relationships, class_name: "Music::SongRelationship", foreign_key: :related_song_id, dependent: :destroy
  has_many :original_songs, through: :inverse_song_relationships, source: :song

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

  # Helper methods for each relationship type
  def covers
    related_songs.merge(Music::SongRelationship.covers)
  end

  def remixes
    related_songs.merge(Music::SongRelationship.remixes)
  end

  def samples
    related_songs.merge(Music::SongRelationship.samples)
  end

  def alternates
    related_songs.merge(Music::SongRelationship.alternates)
  end

  def covered_by
    original_songs.merge(Music::SongRelationship.covers)
  end

  def remixed_by
    original_songs.merge(Music::SongRelationship.remixes)
  end

  def sampled_by
    original_songs.merge(Music::SongRelationship.samples)
  end

  def alternated_by
    original_songs.merge(Music::SongRelationship.alternates)
  end
end

# == Schema Information
#
# Table name: music_songs
#
#  id            :bigint           not null, primary key
#  description   :text
#  duration_secs :integer
#  isrc          :string(12)
#  lyrics        :text
#  notes         :text
#  release_year  :integer
#  slug          :string           not null
#  title         :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_music_songs_on_isrc          (isrc) UNIQUE WHERE (isrc IS NOT NULL)
#  index_music_songs_on_release_year  (release_year)
#  index_music_songs_on_slug          (slug) UNIQUE
#
class Music::Song < ApplicationRecord
  include SearchIndexable

  extend FriendlyId

  friendly_id :title, use: [:slugged, :finders]

  # Associations
  has_many :song_artists, -> { order(:position) }, class_name: "Music::SongArtist", dependent: :destroy
  has_many :artists, through: :song_artists, class_name: "Music::Artist"
  has_many :tracks, class_name: "Music::Track", dependent: :destroy
  has_many :releases, through: :tracks, class_name: "Music::Release"
  has_many :albums, through: :releases, class_name: "Music::Album"
  has_many :credits, as: :creditable, class_name: "Music::Credit", dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy
  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :list_items, as: :listable, dependent: :destroy
  has_many :lists, through: :list_items

  # Ranking associations
  has_many :ranked_items, as: :item, dependent: :destroy

  # Category associations
  has_many :category_items, as: :item, dependent: :destroy, inverse_of: :item
  has_many :categories, through: :category_items, class_name: "Music::Category", inverse_of: :songs

  # External link associations
  has_many :external_links, as: :parent, dependent: :destroy

  # Song relationships
  has_many :song_relationships, class_name: "Music::SongRelationship", foreign_key: :song_id, dependent: :destroy
  has_many :related_songs, through: :song_relationships, source: :related_song

  # Reverse relationships (e.g., songs that cover this song)
  has_many :inverse_song_relationships, class_name: "Music::SongRelationship", foreign_key: :related_song_id, dependent: :destroy
  has_many :original_songs, through: :inverse_song_relationships, source: :song

  # Validations
  validates :title, presence: true
  validates :duration_secs, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
  validates :release_year, numericality: {only_integer: true, greater_than: 1900, less_than_or_equal_to: Date.current.year + 1}, allow_nil: true
  validates :isrc, length: {is: 12}, allow_blank: true
  validates :isrc, uniqueness: {allow_blank: true}

  # Callbacks
  before_validation :normalize_title
  before_save :normalize_isrc
  after_commit :queue_recording_id_enrichment, on: :create

  # Scopes
  scope :with_lyrics, -> { where.not(lyrics: [nil, ""]) }
  scope :with_notes, -> { where.not(notes: [nil, ""]) }
  scope :by_duration, ->(seconds) { where("duration_secs <= ?", seconds) }
  scope :longer_than, ->(seconds) { where("duration_secs > ?", seconds) }
  scope :released_in, ->(year) { where(release_year: year) }
  scope :released_before, ->(year) { where("release_year <= ?", year) }
  scope :released_after, ->(year) { where("release_year >= ?", year) }
  scope :released_in_range, ->(start_year, end_year) { where(release_year: start_year..end_year) }

  scope :with_identifier, ->(identifier_type, value) {
    joins(:identifiers).where(identifiers: {identifier_type: identifier_type, value: value})
  }

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

  # Update release_year from MusicBrainz recording identifiers
  # Looks up all linked MBIDs and sets release_year to the minimum year found
  # Returns true if updated, false if not
  def update_release_year_from_identifiers!
    # Get all MusicBrainz recording IDs for this song
    mbids = identifiers.where(identifier_type: :music_musicbrainz_recording_id).pluck(:value)
    return false if mbids.empty?

    recording_search = ::Music::Musicbrainz::Search::RecordingSearch.new
    mb_year = nil

    mbids.each do |mbid|
      begin
        result = recording_search.lookup_by_mbid(mbid)
        next unless result[:success] && result[:data]

        recording = result[:data]["recordings"]&.first
        first_release_date = recording&.dig("first-release-date")
        next unless first_release_date.present?

        # Extract year from date (formats: YYYY, YYYY-MM, YYYY-MM-DD)
        year = first_release_date.to_s[0..3].to_i
        next if year < 1900 || year > Date.current.year + 1

        mb_year = year if mb_year.nil? || year < mb_year
      rescue ::Music::Musicbrainz::Exceptions::QueryError
        # Invalid MBID format - skip this one but continue with others
        next
      end
    end

    return false unless mb_year

    # Only update if new year is earlier or current year is nil
    if release_year.nil? || mb_year < release_year
      old_year = release_year
      update!(release_year: mb_year)
      Rails.logger.info "Song #{id} release_year updated from #{old_year || "nil"} to #{mb_year}"
      true
    else
      false
    end
  end

  # Class Methods
  def self.find_duplicates
    # Use LOWER() for case-insensitive grouping
    duplicate_titles = Music::Song
      .group("LOWER(title)")
      .having("COUNT(*) > 1")
      .pluck("LOWER(title)")

    duplicates = []

    duplicate_titles.each do |normalized_title|
      # Find all songs with this title (case-insensitive)
      songs_with_title = Music::Song
        .where("LOWER(title) = ?", normalized_title)
        .includes(:artists)

      # Group by artist IDs (sorted for comparison)
      grouped_by_artists = songs_with_title.group_by do |song|
        song.artists.pluck(:id).sort
      end

      # Only keep groups with > 1 song (actual duplicates)
      # SKIP groups where artist_ids is empty to prevent merging different songs
      # that happen to share a title but have no artist data (e.g., "Intro", "Outro")
      grouped_by_artists.each do |artist_ids, songs|
        next if artist_ids.empty? # Skip songs without artists
        duplicates << songs if songs.count > 1
      end
    end

    duplicates
  end

  # Search Methods
  def as_indexed_json
    {
      title: title,
      artist_names: artists.map(&:name),
      artist_ids: artists.map(&:id),
      album_ids: albums.map(&:id),
      category_ids: categories.active.pluck(:id)
    }
  end

  private

  def normalize_title
    self.title = Services::Text::QuoteNormalizer.call(title) if title.present?
  end

  def normalize_isrc
    self.isrc = nil if isrc.blank?
  end

  def queue_recording_id_enrichment
    Music::EnrichSongRecordingIdsJob.perform_in(1.minute, id)
  end
end

# == Schema Information
#
# Table name: identifiers
#
#  id                :bigint           not null, primary key
#  identifiable_type :string           not null
#  identifier_type   :integer          not null
#  value             :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  identifiable_id   :bigint           not null
#
# Indexes
#
#  index_identifiers_on_identifiable    (identifiable_type,identifiable_id)
#  index_identifiers_on_lookup_unique   (identifiable_type,identifier_type,value,identifiable_id) UNIQUE
#  index_identifiers_on_type_and_value  (identifiable_type,value)
#
class Identifier < ApplicationRecord
  # Associations
  belongs_to :identifiable, polymorphic: true

  # Enums - Domain-prefixed identifier types
  enum :identifier_type, {
    # Books
    books_isbn10: 0,
    books_isbn13: 1,
    books_asin: 2,
    books_ean13: 3,
    books_goodreads_id: 4,
    books_librarything_id: 5,
    books_openlibrary_id: 6,
    books_bookshop_org_id: 7,
    books_worldcat_id: 8,
    books_google_books_id: 9,

    # Music - Artists
    music_musicbrainz_artist_id: 100,
    music_isni: 101,
    music_discogs_artist_id: 102,
    music_allmusic_artist_id: 103,

    # Music - Albums
    music_musicbrainz_release_group_id: 200,
    music_musicbrainz_release_id: 201,
    music_asin: 202,
    music_discogs_release_id: 203,
    music_allmusic_album_id: 204,

    # Music - Songs
    music_musicbrainz_recording_id: 300,
    music_musicbrainz_work_id: 301,
    music_isrc: 302,

    # Video Games
    games_igdb_id: 400,
    games_rawg_id: 401,
    games_igdb_company_id: 410
  }

  # Validations
  validates :identifiable, presence: true
  validates :identifier_type, presence: true
  validates :value, presence: true, length: {maximum: 255}
  validates :value, uniqueness: {scope: [:identifiable_type, :identifiable_id, :identifier_type]}

  # Scopes
  scope :for_domain, ->(domain) { where(identifiable_type: domain) }
  scope :by_type, ->(type) { where(identifier_type: type) }
  scope :by_value, ->(value) { where(value: value) }

  # Class methods for domain filtering
  def self.books
    for_domain(["Books::Book"])
  end

  def self.music_artists
    for_domain(["Music::Artist"])
  end

  def self.music_albums
    for_domain(["Music::Album"])
  end

  def self.music_songs
    for_domain(["Music::Song"])
  end

  def self.music_releases
    for_domain(["Music::Release"])
  end

  def self.games
    for_domain(["Games::Game"])
  end

  # Instance methods
  def domain
    identifiable_type.split("::").first.downcase
  end

  def media_type
    identifiable_type.split("::").last.downcase
  end
end

# Music::Song

## Summary
Represents a musical composition independent of any specific recording. This is the canonical song that can appear on multiple releases, albums, and have various relationships (covers, remixes, samples, etc.). **Updated August 2025**: Now supports direct artist associations independent of albums.

## Associations
- `has_many :song_artists, -> { order(:position) }, class_name: "Music::SongArtist"` — Join table for artist associations with position ordering
- `has_many :artists, through: :song_artists, class_name: "Music::Artist"` — All artists associated with this song (independent of album artists)
- `has_many :tracks, class_name: "Music::Track"` — All track appearances of this song
- `has_many :releases, through: :tracks, class_name: "Music::Release"` — All releases that include this song
- `has_many :albums, through: :releases, class_name: "Music::Album"` — All albums that include this song
- `has_many :credits, as: :creditable, class_name: "Music::Credit"` — Polymorphic association for song-specific credits
- `has_many :song_relationships, class_name: "Music::SongRelationship", foreign_key: :song_id, dependent: :destroy` — Outbound relationships (this song covers/remixes others)
- `has_many :related_songs, through: :song_relationships, source: :related_song` — Songs that this song relates to
- `has_many :inverse_song_relationships, class_name: "Music::SongRelationship", foreign_key: :related_song_id, dependent: :destroy` — Inbound relationships (other songs cover/remix this one)
- `has_many :original_songs, through: :inverse_song_relationships, source: :song` — Songs that relate to this song
- `has_many :identifiers, as: :identifiable, dependent: :destroy` — External identifiers for data import and deduplication
- `has_many :category_items, as: :item, dependent: :destroy` — Polymorphic association for category assignments
- `has_many :categories, through: :category_items, class_name: "Music::Category"` — All categories this song belongs to
- `has_many :external_links, as: :parent, dependent: :destroy` — **NEW (Sept 2025)**: External links (purchase, information, reviews) for this song

## Public Methods

### `#covers`
Returns songs that this song covers
- Returns: ActiveRecord::Relation of Music::Song

### `#remixes`
Returns songs that this song remixes
- Returns: ActiveRecord::Relation of Music::Song

### `#samples`
Returns songs that this song samples
- Returns: ActiveRecord::Relation of Music::Song

### `#alternates`
Returns alternate versions of this song
- Returns: ActiveRecord::Relation of Music::Song

### `#covered_by`
Returns songs that cover this song
- Returns: ActiveRecord::Relation of Music::Song

### `#remixed_by`
Returns songs that remix this song
- Returns: ActiveRecord::Relation of Music::Song

### `#sampled_by`
Returns songs that sample this song
- Returns: ActiveRecord::Relation of Music::Song

### `#alternated_by`
Returns alternate versions of this song
- Returns: ActiveRecord::Relation of Music::Song

### `#as_indexed_json`
Returns the data structure for OpenSearch indexing
- Returns: Hash - Includes title, artist_names (array), artist_ids (array), album_ids, and active category IDs
- Used by `Search::Music::SongIndex` for indexing operations
- **Updated August 2025**: Now returns arrays of artist names and IDs from direct song-artist associations

**Removed August 2025**: `#primary_artist_id` method (replaced with direct artist associations)

### `#album_ids`
Returns an array of album IDs that contain this song
- Returns: Array of Integer - All album IDs through releases and tracks
- Used for OpenSearch indexing to enable album-based filtering

## Validations
- `title` — presence
- `slug` — presence, uniqueness
- `duration_secs` — numericality (integer, greater than 0), allow nil
- `release_year` — numericality (integer, 1900 to current year + 1), allow nil
- `isrc` — length is 12, allow blank, uniqueness when present

## Scopes
- `with_lyrics` — Songs that have lyrics
- `by_duration(seconds)` — Songs with duration <= given seconds
- `longer_than(seconds)` — Songs with duration > given seconds
- `released_in(year)` — Songs released in specific year
- `released_before(year)` — Songs released before given year
- `released_after(year)` — Songs released after given year

## Constants
None

## Callbacks
- Includes `SearchIndexable` concern for automatic OpenSearch indexing
- `after_save :queue_for_indexing` - Queues for background indexing when created or updated
- `after_destroy :queue_for_unindexing` - Queues for background removal from search index

## Dependencies
- FriendlyId gem for slug generation and lookup
- `SearchIndexable` concern for automatic OpenSearch indexing
- `Search::Music::SongIndex` for OpenSearch operations
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
- `has_many :list_items, as: :listable, dependent: :destroy` — Polymorphic association for list membership (user and editorial lists)
- `has_many :lists, through: :list_items` — All lists containing this song
- `has_many :ranked_items, as: :item, dependent: :destroy` — **NEW (Oct 2025)**: Rankings of this song in various ranking configurations
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

## Class Methods

### `self.find_duplicates`
**NEW (October 2025)**: Finds duplicate songs based on case-insensitive title matching and identical artist sets.

- Returns: Array of Arrays - Each inner array contains duplicate Music::Song records
- Matching criteria:
  - Title matches (case-insensitive: "Imagine" == "imagine" == "IMAGINE")
  - Artists match (same set of artist IDs, order-independent)
  - **IMPORTANT**: Songs without any artist data are excluded to prevent false positives
- Safety guard: Skips songs with no artists (e.g., "Intro", "Outro") that may be different songs
- Used by: `music:songs:find_duplicates` rake task
- Example:
  ```ruby
  duplicates = Music::Song.find_duplicates
  duplicates.each do |group|
    puts "Found #{group.count} duplicates of '#{group.first.title}'"
  end
  ```

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

## Merge Capabilities

**NEW (October 2025)**: Songs can be merged to consolidate duplicate entries using the `Music::Song::Merger` service.

### When to Merge Songs
- Same song imported via different routes (series import, album import, manual)
- Multiple MusicBrainz recording IDs for the same canonical song
- Merging old incomplete record into new enriched version
- Consolidating when better metadata becomes available

### Merge Behavior
When merging songs via `Music::Song::Merger.call(source: song_a, target: song_b)`:

**Associations Transferred to Target**:
- All tracks (song appearances on releases)
- All identifiers (MusicBrainz recording IDs, ISRCs, etc.)
- All category_items (genres/styles) - duplicates skipped via find_or_create
- All external_links (purchase/review/info links)
- All list_items (list appearances) - duplicates skipped, position preserved
- Forward song_relationships (songs this song relates to) - self-references skipped
- Inverse song_relationships (songs that relate to this song) - self-references destroyed

**Associations NOT Transferred**:
- song_artists - Target's artists preserved, source's destroyed
- credits - Not currently populated; deferred for future
- ai_chats - Not valuable to preserve; destroyed with source
- ranked_items - Source's destroyed; target's preserved; triggers recalculation

**Additional Actions**:
- Source song destroyed after successful merge
- Target song touched to trigger search reindexing
- Ranking recalculation jobs scheduled for affected configurations
- All operations in single database transaction (atomic)

### Admin Access

**Avo Admin Interface**:
- Navigate to target song (the one to keep)
- Click "Merge Another Song Into This One" action
- Enter source song ID (the duplicate to delete)
- Confirm action cannot be undone
- Review merge results

**Rake Task** (for bulk operations):
- Find duplicates: `bin/rails music:songs:find_duplicates` (dry-run)
- Auto-merge: `MERGE=true bin/rails music:songs:find_duplicates`
- See `lib/tasks/music/songs.rake` for implementation

See `docs/lib/music/song/merger.md` for detailed merge service documentation.

## Dependencies
- FriendlyId gem for slug generation and lookup
- `SearchIndexable` concern for automatic OpenSearch indexing
- `Search::Music::SongIndex` for OpenSearch operations
- `Music::Song::Merger` service for merging duplicate songs (Oct 2025)
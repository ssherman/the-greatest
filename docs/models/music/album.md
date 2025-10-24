# Music::Album

## Summary
Represents a canonical album/work (e.g., "Dark Side of the Moon"). This is the conceptual album, while commercial manifestations are tracked in the `Music::Release` model. **Updated August 2025**: Now supports multiple artists through join table.

## Associations
- `has_many :album_artists, -> { order(:position) }, class_name: "Music::AlbumArtist"` — Join table for artist associations with position ordering
- `has_many :artists, through: :album_artists, class_name: "Music::Artist"` — All artists associated with this album (supports multiple artists)
- `has_many :releases, class_name: "Music::Release"` — All commercial releases of this album (CD, vinyl, digital, etc.)
- `has_many :credits, as: :creditable, class_name: "Music::Credit"` — Polymorphic association for all artistic and technical credits
- `has_many :identifiers, as: :identifiable, dependent: :destroy` — External identifiers for data import and deduplication
- `has_many :category_items, as: :item, dependent: :destroy` — Polymorphic association for category assignments
- `has_many :categories, through: :category_items, class_name: "Music::Category"` — All categories this album belongs to
- `has_many :images, as: :parent, dependent: :destroy` — **NEW (Sept 2025)**: All images for this album (covers, artwork, liner notes, etc.)
- `has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"` — **NEW (Sept 2025)**: Primary image for ranking views and display
- `has_many :external_links, as: :parent, dependent: :destroy` — **NEW (Sept 2025)**: External links (purchase, information, reviews) for this album
- `has_many :list_items, as: :listable, dependent: :destroy` — Polymorphic association for list membership (user and editorial lists)
- `has_many :lists, through: :list_items` — All lists containing this album
- `has_many :ranked_items, as: :item, dependent: :destroy` — **NEW (Oct 2025)**: Rankings of this album in various ranking configurations

## Public Methods

### `#as_indexed_json`
Returns the data structure for OpenSearch indexing
- Returns: Hash - Includes title, artist_names (array), artist_ids (array), and active category IDs
- Used by `Search::Music::AlbumIndex` for indexing operations
- **Updated August 2025**: Now returns arrays of artist names and IDs instead of single primary artist

## Validations
- `title` — presence
- `slug` — presence, uniqueness
- `release_year` — numericality (integer only), allow nil
- **Removed August 2025**: `primary_artist` validation (replaced with multiple artist support)

## Scopes

### `with_identifier(identifier_type, value)`
Finds albums by external identifier type and value. Joins with identifiers table for efficient querying.
- Parameters: 
  - `identifier_type` (String) - Type of identifier (e.g., "music_musicbrainz_release_group_id")
  - `value` (String) - Identifier value
- Returns: ActiveRecord::Relation
- Usage: `Music::Album.with_identifier("music_musicbrainz_release_group_id", "abc-123")`

### `with_musicbrainz_release_group_id(mbid)`
Convenience scope for finding albums by MusicBrainz Release Group ID. Used extensively during import operations.
- Parameters: `mbid` (String) - MusicBrainz Release Group ID
- Returns: ActiveRecord::Relation  
- Usage: `Music::Album.with_musicbrainz_release_group_id("f5093c06-23e3-404f-aeaa-40f72885ee3a")`
- **Added September 2025**: Supports MusicBrainz series import functionality

## Constants
None

## Callbacks
- Includes `SearchIndexable` concern for automatic OpenSearch indexing
- `after_save :queue_for_indexing` - Queues for background indexing when created or updated
- `after_destroy :queue_for_unindexing` - Queues for background removal from search index

## Dependencies
- FriendlyId gem for slug generation and lookup
- `SearchIndexable` concern for automatic OpenSearch indexing
- `Search::Music::AlbumIndex` for OpenSearch operations

## Album Merging

**NEW (Oct 2025)**: Albums can be merged when duplicate entries are found (e.g., from multiple MusicBrainz imports).

### Merge Process
Use the `Music::Album::Merger` service to combine two album records:

```ruby
result = Music::Album::Merger.call(
  source: duplicate_album,
  target: canonical_album
)
```

### What Gets Merged
- Releases, identifiers, categories, images, external links, list items
- Target album's artists are preserved (source artists are NOT merged)
- Source album's ranked_items are destroyed (target rankings preserved)
- Search index automatically updated for both albums
- Ranking configurations recalculated via background jobs

### Admin Interface
Available as "Merge Another Album Into This One" action in Avo admin for Music::Album resources.

See [Music::Album::Merger](../../lib/music/album/merger.md) for complete merge documentation.
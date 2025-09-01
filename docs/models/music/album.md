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
None

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
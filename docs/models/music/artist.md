# Music::Artist

## Summary
Represents a musical artist, which can be either an individual person or a band. Core model for the music domain, used as the primary entity for credits, albums, and memberships. **Updated August 2025**: Now supports many-to-many relationships with both albums and songs.

## Associations
- `has_many :band_memberships, class_name: "Music::Membership", foreign_key: :artist_id` — All memberships where this artist is a band
- `has_many :memberships, class_name: "Music::Membership", foreign_key: :member_id` — All memberships where this artist is a person (member of a band)
- `has_many :album_artists, class_name: "Music::AlbumArtist"` — Join table for album associations
- `has_many :albums, through: :album_artists, class_name: "Music::Album"` — All albums this artist is associated with (supports multiple artists per album)
- `has_many :song_artists, class_name: "Music::SongArtist"` — Join table for song associations  
- `has_many :songs, through: :song_artists, class_name: "Music::Song"` — All songs this artist is associated with (independent of albums)
- `has_many :credits, class_name: "Music::Credit"` — All credits (artistic/technical) associated with this artist
- `has_many :ai_chats, as: :parent, dependent: :destroy` — Polymorphic association for AI chat conversations
- `has_many :identifiers, as: :identifiable, dependent: :destroy` — External identifiers for data import and deduplication
- `has_many :category_items, as: :item, dependent: :destroy` — Polymorphic association for category assignments
- `has_many :categories, through: :category_items, class_name: "Music::Category"` — All categories this artist belongs to
- `has_many :images, as: :parent, dependent: :destroy` — **NEW (Sept 2025)**: All images for this artist (photos, promotional materials, etc.)
- `has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"` — **NEW (Sept 2025)**: Primary image for ranking views and display

## Public Methods

### `#person?`
Returns true if the artist is a person (not a band)
- Returns: Boolean

### `#band?`
Returns true if the artist is a band
- Returns: Boolean

### `#populate_details_with_ai!`
Populates artist details using AI services
- Returns: Services::Ai::Tasks::ArtistDetailsTask result object
- Side effects: Updates artist attributes with AI-generated data

### `#as_indexed_json`
Returns the data structure for OpenSearch indexing
- Returns: Hash - Includes name, slug, description, country, years, kind, and active category IDs
- Used by `Search::Music::ArtistIndex` for indexing operations

## Validations
- `name` — presence
- `kind` — presence (must be either person or band)
- `country` — length is 2 (ISO-3166 alpha-2), allow blank
- Custom: `date_consistency` — Ensures only people have year_died and only bands have year_formed/year_disbanded

## Scopes
- `people` — All artists of kind person
- `bands` — All artists of kind band
- `active` — All bands that have not been disbanded (year_disbanded is nil)

## Constants
- `enum :kind, { person: 0, band: 1 }` — Distinguishes between people and bands

## Callbacks
- Includes `SearchIndexable` concern for automatic OpenSearch indexing
- `after_save :queue_for_indexing` - Queues for background indexing when created or updated
- `after_destroy :queue_for_unindexing` - Queues for background removal from search index

## Dependencies
- FriendlyId gem for slug generation and lookup from name
- Services::Ai::Tasks::ArtistDetailsTask for AI-powered data enrichment
- `SearchIndexable` concern for automatic OpenSearch indexing
- `Search::Music::ArtistIndex` for OpenSearch operations
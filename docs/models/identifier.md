# Identifier

## Summary
Represents external identifiers for various media objects (books, music, movies, games). Core model for data import and deduplication workflows. Uses polymorphic associations to link to any identifiable object.

## Associations
- `belongs_to :identifiable, polymorphic: true` - The object that owns this identifier (e.g., Music::Artist, Books::Book)

## Public Methods

### Class Methods

#### `self.books`
Returns all identifiers for book-related objects
- Returns: ActiveRecord::Relation of Identifier

#### `self.music_artists`
Returns all identifiers for music artist objects
- Returns: ActiveRecord::Relation of Identifier

#### `self.music_albums`
Returns all identifiers for music album objects
- Returns: ActiveRecord::Relation of Identifier

#### `self.music_songs`
Returns all identifiers for music song objects
- Returns: ActiveRecord::Relation of Identifier

#### `self.music_releases`
Returns all identifiers for music release objects
- Returns: ActiveRecord::Relation of Identifier

#### `self.video_games`
Returns all identifiers for video game objects
- Returns: ActiveRecord::Relation of Identifier

#### `self.for_domain(domain)`
Returns identifiers for a specific domain
- Parameters: domain (String) - Domain name (e.g., "books", "music")
- Returns: ActiveRecord::Relation of Identifier

#### `self.by_type(type)`
Returns identifiers of a specific type
- Parameters: type (String/Symbol) - Identifier type enum value
- Returns: ActiveRecord::Relation of Identifier

#### `self.by_value(value)`
Returns identifiers with a specific value
- Parameters: value (String) - Identifier value to search for
- Returns: ActiveRecord::Relation of Identifier

### Instance Methods

#### `#domain`
Returns the domain this identifier belongs to
- Returns: String (e.g., "books", "music", "video_games")

#### `#media_type`
Returns the media type this identifier belongs to
- Returns: String (e.g., "artist", "album", "book")

## Validations
- `identifiable` - presence
- `identifier_type` - presence, inclusion in enum values
- `value` - presence, length maximum 255 characters
- `value` - uniqueness within scope of `[:identifiable_type, :identifiable_id, :identifier_type]`

## Scopes
- `for_domain(domain)` - Filter by domain (books, music, video_games)
- `by_type(type)` - Filter by specific identifier type
- `by_value(value)` - Filter by identifier value

## Constants
- `IDENTIFIER_TYPES` - Enum defining all 47 identifier types across domains:
  - **Books**: `books_isbn10`, `books_isbn13`, `books_asin`, `books_goodreads_id`
  - **Music Artists**: `music_musicbrainz_artist_id`, `music_discogs_artist_id`, `music_allmusic_artist_id`, `music_spotify_artist_id`
  - **Music Albums**: `music_musicbrainz_release_id`, `music_discogs_release_id`, `music_allmusic_album_id`, `music_spotify_album_id`
  - **Music Songs**: `music_musicbrainz_recording_id`, `music_discogs_track_id`, `music_allmusic_song_id`, `music_spotify_track_id`
  - **Music Releases**: `music_musicbrainz_release_id`, `music_discogs_release_id`, `music_asin`
  - **Video Games**: `video_games_igdb_id`

## Callbacks
None currently defined

## Dependencies
- Rails polymorphic associations
- PostgreSQL 17 for optimized composite indexes

## Database Indexes
- `UNIQUE(identifiable_type, identifier_type, value, identifiable_id)` - Primary unique index for specific lookups
- `INDEX(identifiable_type, value)` - Secondary index for value-only searches (e.g., finding books by any ISBN format)

## Usage Examples

```ruby
# Add identifier to an artist
artist = Music::Artist.find(1)
identifier = artist.identifiers.create!(
  identifier_type: :music_musicbrainz_artist_id,
  value: "5441c29d-3602-4898-b1a1-b77fa23b8e50"
)

# Find all identifiers for an object
identifiers = artist.identifiers.order(:identifier_type)

# Find by specific type and value
artist = Identifier.find_by(
  identifier_type: :music_musicbrainz_artist_id,
  value: "5441c29d-3602-4898-b1a1-b77fa23b8e50"
)&.identifiable

# Domain-specific queries
book_identifiers = Identifier.books
music_artist_identifiers = Identifier.music_artists
```

## Related Services
- `IdentifierService` - Business logic for identifier operations 
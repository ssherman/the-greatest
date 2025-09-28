# DataImporters::Music::Album::Providers::MusicBrainz

## Summary
Imports album (release group) data from MusicBrainz using either direct lookup (by Release Group ID) or search (by artist+title). Handles automatic artist import from artist-credit data, title/year mapping, and genre processing from both tags and genres fields.

## Associations
- Uses `::Music::Album` model (no direct associations inside provider)
- Creates `::Identifier` records via `album.identifiers.build`
- Creates `::CategoryItem` records to associate `::Music::Category` with albums

## Public Methods

### `#populate(album, query:)`
Populates a `::Music::Album` with MusicBrainz data and categories using either direct lookup or search
- Parameters:
  - `album` (Music::Album) — Target album to populate
  - `query` (ImportQuery) — Query with either `release_group_musicbrainz_id` OR (`artist` + optional `title`), optional `primary_albums_only`
- Returns: Result (success, data_populated|errors)
- Side effects: Builds identifiers, creates genre categories and associations, imports/associates artists automatically when using Release Group ID

## Validations
- Delegated to `::Music::Album` model

## Scopes
- None

## Constants
- None

## Callbacks
- None

## Dependencies
- `::Music::Musicbrainz::Search::ReleaseGroupSearch` — search and lookup adapter
- `::DataImporters::Music::Artist::Importer` — automatic artist import for Release Group ID lookups
- `::Identifier` — stores external IDs
- `::Music::Category`, `::CategoryItem` — categories and associations

## Error Handling
- **Network failures**: Return failure result with error details
- **Invalid API responses**: Return failure result with parsing errors
- **Empty search results**: Return success result with empty data (allows album creation with basic info)
- **Artist import failures**: Return failure result when artist-credit processing fails
- **Provider exceptions**: Caught and returned as failure results

### Enhancement Philosophy
This provider operates as an **enhancement service** rather than a **validation gate**:
- "Not found in MusicBrainz" returns success with empty `data_populated`
- Allows albums not yet in the database to be created with basic user-provided information
- Prevents blocking of async providers (AI Description, Amazon) that depend on persisted items
- Enables graceful degradation when MusicBrainz is unavailable

## Private Methods

### `#lookup_release_group_by_mbid(mbid)`
Executes release group lookup on MusicBrainz using direct MBID lookup
- Parameters: mbid (String) - MusicBrainz Release Group ID
- Returns: lookup result Hash

### `#search_release_groups_by_artist(album, query)`
Executes release group search by artist (existing logic)
- Parameters: album (Music::Album), query (ImportQuery)
- Returns: search result Hash

### `#import_artists_from_artist_credits(artist_credits)`
Import artists from MusicBrainz artist-credit data
- Parameters: artist_credits (Array) - artist-credit array from MusicBrainz
- Returns: Array of Music::Artist instances
- Uses existing artist importer with MusicBrainz IDs for each artist

### `#get_artist_musicbrainz_id(artist)`
Finds artist MBID from identifiers

### `#search_for_release_groups(artist_mbid, query)`
Selects search strategy (by title vs all albums)

### `#populate_album_data(album, release_group_data, artists)`
Maps title, artists, and first-release-year
- Parameters: album (Music::Album), release_group_data (Hash), artists (Array of Music::Artist)
- Associates all artists with the album via album_artists

### `#create_identifiers(album, release_group_data)`
Builds MusicBrainz release group identifier

### `#create_categories_from_musicbrainz_data(album, release_group_data)`
- Genres: top 5 non-zero entries from both "tags" and "genres" fields (normalized)
- Associates via `CategoryItem`
- Logs and re-raises on error

### `#extract_category_names_from_field(release_group_data, field_name)`
Extracts and processes category names from either "tags" or "genres" field
- Parameters: release_group_data (Hash), field_name (String - "tags" or "genres")
- Returns: Array of normalized category names (top 5)

## Examples

### Release Group ID Import (New)
```ruby
# Direct import by MusicBrainz Release Group ID
# Automatically imports artists from artist-credit data
query = ImportQuery.new(release_group_musicbrainz_id: "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2")
result = DataImporters::Music::Album::Providers::MusicBrainz.new.populate(album, query: query)
```

### Artist + Title Import (Existing)
```ruby
# Traditional import by artist instance and title
query = ImportQuery.new(artist: pink_floyd, title: "The Wall", primary_albums_only: true)
result = DataImporters::Music::Album::Providers::MusicBrainz.new.populate(album, query: query)
```

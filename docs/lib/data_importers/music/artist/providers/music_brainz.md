# DataImporters::Music::Artist::Providers::MusicBrainz

## Summary
Imports artist data from MusicBrainz and enriches it with identifiers, genres (from tags), and location categories (from area/begin-area). Handles name, kind, country, and lifespan mapping.

## Associations
- Uses `::Music::Artist` model (no direct associations inside provider)
- Creates `::Identifier` records via `artist.identifiers.build`
- Creates `::CategoryItem` records to associate `::Music::Category` with artists

## Public Methods

### `#populate(artist, query:)`
Populates a `::Music::Artist` with MusicBrainz data and categories
- Parameters:
  - `artist` (Music::Artist) — Target artist to populate
  - `query` (ImportQuery) — Query with `name`
- Returns: Result (success, data_populated|errors)
- Side effects: Builds identifiers, creates categories and associations

## Validations
- Delegated to `::Music::Artist` model

## Scopes
- None

## Constants
- None

## Callbacks
- None

## Dependencies
- `::Music::Musicbrainz::Search::ArtistSearch` — search adapter
- `::Identifier` — stores external IDs
- `::Music::Category`, `::CategoryItem` — categories and associations

## Error Handling
- **Network failures**: Return failure result with error details
- **Invalid API responses**: Return failure result with parsing errors  
- **Empty search results**: Return success result with empty data (allows artist creation with basic info)
- **Provider exceptions**: Caught and returned as failure results

### Enhancement Philosophy
This provider operates as an **enhancement service** rather than a **validation gate**:
- "Not found in MusicBrainz" returns success with empty `data_populated`
- Allows artists not yet in the database to be created with basic user-provided information
- Prevents blocking of async providers (AI Description, Amazon) that depend on persisted items
- Enables graceful degradation when MusicBrainz is unavailable

## Private Methods

### `#search_for_artist(name)`
Wraps search service

### `#populate_artist_data(artist, artist_data)`
Maps name, kind, country, lifespan

### `#create_identifiers(artist, artist_data)`
Builds MusicBrainz and ISNI identifiers

### `#create_categories_from_musicbrainz_data(artist, artist_data)`
- Genres: top 5 non-zero tags (normalized)
- Location: `area` and `begin-area`
- Creates categories with `category_type` set to `genre` or `location`
- Associates via `CategoryItem`
- Logs and re-raises on error

## Example
```ruby
result = DataImporters::Music::Artist::Providers::MusicBrainz.new.populate(artist, query: ImportQuery.new(name: "Pink Floyd"))
```
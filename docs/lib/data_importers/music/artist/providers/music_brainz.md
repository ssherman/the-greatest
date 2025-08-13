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
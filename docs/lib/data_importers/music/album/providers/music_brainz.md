# DataImporters::Music::Album::Providers::MusicBrainz

## Summary
Imports album (release group) data from MusicBrainz and enriches it with identifiers and genre categories (from tags). Handles title, primary artist, and release year mapping.

## Associations
- Uses `::Music::Album` model (no direct associations inside provider)
- Creates `::Identifier` records via `album.identifiers.build`
- Creates `::CategoryItem` records to associate `::Music::Category` with albums

## Public Methods

### `#populate(album, query:)`
Populates a `::Music::Album` with MusicBrainz data and categories
- Parameters:
  - `album` (Music::Album) — Target album to populate
  - `query` (ImportQuery) — Query with `artist`, optional `title`, `primary_albums_only`
- Returns: Result (success, data_populated|errors)
- Side effects: Builds identifiers, creates genre categories and associations

## Validations
- Delegated to `::Music::Album` model

## Scopes
- None

## Constants
- None

## Callbacks
- None

## Dependencies
- `::Music::Musicbrainz::Search::ReleaseGroupSearch` — search adapter
- `::Identifier` — stores external IDs
- `::Music::Category`, `::CategoryItem` — categories and associations

## Private Methods

### `#get_artist_musicbrainz_id(artist)`
Finds artist MBID from identifiers

### `#search_for_release_groups(artist_mbid, query)`
Selects search strategy (by title vs all)

### `#populate_album_data(album, release_group_data, artist)`
Maps title, primary artist, and first-release-year

### `#create_identifiers(album, release_group_data)`
Builds MusicBrainz release group identifier

### `#create_categories_from_musicbrainz_data(album, release_group_data)`
- Genres: top 5 non-zero tags (normalized)
- Associates via `CategoryItem`
- Logs and re-raises on error

## Example
```ruby
result = DataImporters::Music::Album::Providers::MusicBrainz.new.populate(album, query: ImportQuery.new(artist: pink_floyd, title: "The Wall"))
```

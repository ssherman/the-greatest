# Music::SearchesController

## Summary
Handles public-facing search requests for the music domain. Executes searches across artists, albums, and songs simultaneously and displays combined results grouped by type.

## Actions

### `index`
Main search action that handles the `/search?q=query` endpoint.

**Parameters:**
- `q` (String) - Search query term from user input

**Behavior:**
- Returns empty arrays and 0 total count if query is blank
- Executes three parallel searches (artists, albums, songs) via OpenSearch
- Converts OpenSearch results to ActiveRecord objects with eager loading
- Displays results in hardcoded order: Artists → Albums → Songs
- Limits: 25 artists, 25 albums, 10 songs

**Instance Variables:**
- `@query` (String) - The search term
- `@artist_results` (Array<Hash>) - Raw OpenSearch results for artists
- `@album_results` (Array<Hash>) - Raw OpenSearch results for albums
- `@song_results` (Array<Hash>) - Raw OpenSearch results for songs
- `@artists` (Array<Music::Artist>) - ActiveRecord artist objects
- `@albums` (Array<Music::Album>) - ActiveRecord album objects
- `@songs` (Array<Music::Song>) - ActiveRecord song objects
- `@total_count` (Integer) - Total number of results across all types

**View:** `app/views/music/searches/index.html.erb`

## Private Methods

### `load_artists(results)`
Converts OpenSearch artist results to ActiveRecord objects while preserving search order.

**Parameters:**
- `results` (Array<Hash>) - OpenSearch results with `:id`, `:score`, `:source` keys

**Returns:** Array<Music::Artist> in the same order as results

**Includes:** `:categories`, `:primary_image` to prevent N+1 queries

**Implementation:**
- Extracts IDs and converts to integers with `.to_i`
- Uses `.uniq` to deduplicate IDs
- Loads records with `where(id: ids)`
- Uses `index_by(&:id)` to create hash lookup
- Maps IDs back to preserve OpenSearch relevance order

### `load_albums(results)`
Converts OpenSearch album results to ActiveRecord objects while preserving search order.

**Parameters:**
- `results` (Array<Hash>) - OpenSearch results with `:id`, `:score`, `:source` keys

**Returns:** Array<Music::Album> in the same order as results

**Includes:** `:artists`, `:categories`, `:primary_image` to prevent N+1 queries

**Implementation:** Same pattern as `load_artists`

### `load_songs(results)`
Converts OpenSearch song results to ActiveRecord objects while preserving search order.

**Parameters:**
- `results` (Array<Hash>) - OpenSearch results with `:id`, `:score`, `:source` keys

**Returns:** Array<Music::Song> in the same order as results

**Includes:** `:artists`, `:categories` to prevent N+1 queries

**Implementation:** Same pattern as `load_artists`

## Dependencies

### Search Classes
- `::Search::Music::Search::ArtistGeneral` - OpenSearch queries for artists
- `::Search::Music::Search::AlbumGeneral` - OpenSearch queries for albums
- `::Search::Music::Search::SongGeneral` - OpenSearch queries for songs

### Models
- `Music::Artist`
- `Music::Album`
- `Music::Song`

### ViewComponents
- `Music::Search::EmptyStateComponent` - No results or blank query message
- `Music::Artists::CardComponent` - Artist card display
- `Music::Albums::CardComponent` - Album card display
- `Music::Songs::ListItemComponent` - Song table row display

## Routes
- `GET /search` - Search results page (maps to `searches#index`)

## Layout
Uses `music/application` layout which includes the search form in the navbar.

## Search Form Location
The search input is embedded in `app/views/layouts/music/application.html.erb` in the navbar-end section. Form submits to this controller's index action.

## Performance Notes
- Three separate OpenSearch queries execute in sequence (not parallel)
- Each query is limited to prevent excessive results (25/25/10)
- Eager loading prevents N+1 queries when rendering results
- OpenSearch handles relevance scoring and filtering

## Result Ordering
Results display in fixed order:
1. Artists section (if any results)
2. Albums section (if any results)
3. Songs section (if any results)

Within each section, results maintain OpenSearch relevance order.

## Design Decisions

### Fixed Result Limits
- Artists: 25 results
- Albums: 25 results
- Songs: 10 results (reduced to save page space)

**Rationale:** Songs take more vertical space in table format. No pagination initially to keep implementation simple.

### No Dynamic Section Ordering
Originally planned to order sections by highest relevance score, but simplified to hardcoded order (Artists → Albums → Songs) for more predictable UX.

### ID Deduplication
Uses `.uniq` on IDs to handle duplicate search results, which can occur if OpenSearch returns the same record multiple times.

### Integer Conversion
OpenSearch returns IDs as strings, but ActiveRecord expects integers. Uses `.to_i` for conversion.

## Future Enhancements
- Pagination for results
- Autocomplete dropdown
- Filter by category/year
- Search history
- Keyboard shortcuts (/ to focus)

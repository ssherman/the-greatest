# Music::Musicbrainz::Search::SeriesSearch

## Summary
Provides search functionality for MusicBrainz series entities. Handles both recording series (for song lists) and release group series (for album lists) with support for direct lookups and complex queries.

## Inheritance
Inherits from `Music::Musicbrainz::Search::BaseSearch`

## Public Methods

### `.entity_type`
Returns the MusicBrainz entity type for series searches.
- Returns: `"series"`

### `.mbid_field`
Returns the MBID field name for series queries.
- Returns: `"sid"` (series ID)

### `.available_fields`
Returns list of searchable fields for series.
- Returns: Array of field names: `["series", "seriesaccent", "alias", "comment", "sid", "tag", "type"]`

### `#search_by_name(name, options = {})`
Searches for series by name.
- Parameters:
  - `name` (String): Series name to search for
  - `options` (Hash): Additional search options (limit, offset, etc.)
- Returns: Hash with `:success`, `:data`, `:errors`, `:metadata`

### `#search_by_type(type, options = {})`
Searches for series by type (e.g., "Release group series", "Recording series").
- Parameters:
  - `type` (String): Series type
  - `options` (Hash): Additional search options
- Returns: Hash with search results

### `#browse_series_with_release_groups(series_mbid, options = {})`
Fetches series with all related release groups using direct lookup API.
- Parameters:
  - `series_mbid` (String): MusicBrainz series ID (UUID format)
  - `options` (Hash): Additional options (limit, offset)
- Returns: Hash with series data including `relations` array
- API Endpoint: `/ws/2/series/{mbid}?inc=release-group-rels`
- Validates MBID format (raises `QueryError` if invalid)

### `#browse_series_with_recordings(series_mbid, options = {})`
Fetches series with all related recordings using direct lookup API.
- Parameters:
  - `series_mbid` (String): MusicBrainz series ID (UUID format)
  - `options` (Hash): Additional options (limit, offset)
- Returns: Hash with series data including `relations` array with recording data
- API Endpoint: `/ws/2/series/{mbid}?inc=recording-rels`
- Validates MBID format (raises `QueryError` if invalid)
- Added in: Task 044 (song series import feature)

### `#search_release_group_series(name = nil, options = {})`
Convenience method for searching release group series specifically.
- Parameters:
  - `name` (String, optional): Series name filter
  - `options` (Hash): Additional search options
- Returns: Hash with search results filtered to "Release group series" type

### `#search_with_criteria(criteria, options = {})`
Builds complex queries with multiple search criteria.
- Parameters:
  - `criteria` (Hash): Field-value pairs (e.g., `{series: "Vice's 100", type: "Release group series"}`)
  - `options` (Hash): Additional search options
- Returns: Hash with search results
- Raises: `QueryError` if invalid fields or no criteria provided

## API Response Transformation

### Browse Response Processing
The `browse_series_with_release_groups` and `browse_series_with_recordings` methods transform single series objects into search-compatible format:

**Input (from MusicBrainz):**
```json
{
  "series": {
    "id": "...",
    "name": "...",
    "relations": [...]
  }
}
```

**Output (transformed):**
```json
{
  "count": 1,
  "offset": 0,
  "results": [{...}],
  "created": "2025-10-03T..."
}
```

## Usage Patterns

### Album Series Import
```ruby
search = SeriesSearch.new
result = search.browse_series_with_release_groups("28cbc99a-875f-4139-b8b0-f1dd520ec62c")

if result[:success]
  relations = result[:data]["results"].first["relations"]
  # Process release groups...
end
```

### Song Series Import
```ruby
search = SeriesSearch.new
result = search.browse_series_with_recordings("b3484a66-a4de-444d-93d3-c99a73656905")

if result[:success]
  relations = result[:data]["results"].first["relations"]
  # Process recordings...
end
```

## Validations
- MBID format: Must be valid UUID format (validated by `validate_mbid!` from BaseSearch)
- Search criteria: At least one criterion required when using `search_with_criteria`
- Field names: Must be in `available_fields` list

## Dependencies
- `Music::Musicbrainz::Client` for API communication
- `Music::Musicbrainz::Search::BaseSearch` for common search functionality
- Handles `Music::Musicbrainz::Error` exceptions

## Error Handling
- Network errors wrapped with context (series_mbid, options)
- Invalid MBID format raises `QueryError`
- Empty criteria raises `QueryError`
- Returns failure hash with `:errors` array on API errors

## Related Classes
- `Music::Musicbrainz::Search::ReleaseGroupSearch` - For fetching release group details
- `Music::Musicbrainz::Search::RecordingSearch` - For fetching recording details
- `DataImporters::Music::Lists::ImportFromMusicbrainzSeries` - Uses browse methods
- `DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries` - Uses `browse_series_with_recordings`

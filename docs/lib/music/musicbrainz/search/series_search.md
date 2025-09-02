# Music::Musicbrainz::Search::SeriesSearch

## Summary
Provides search and browse functionality for MusicBrainz Series API. Specialized in finding and retrieving series data, particularly "Release group series" lists like music rankings and "best of" compilations. Core component for importing ranked music lists with associated release groups and rankings.

## Inheritance
- Inherits from `Music::Musicbrainz::Search::BaseSearch`
- Follows established MusicBrainz search class patterns

## Public Methods

### Search Methods

#### `#search_by_name(name, options = {})`
Search for series by name using the "series" field
- Parameters: name (String) - the series name to search for, options (Hash) - additional search options
- Returns: Hash - search results with series data
- Usage: Finding series like "Rolling Stone's 500 Greatest Albums"

#### `#search_by_name_with_diacritics(name, options = {})`
Search for series by name preserving diacritics using "seriesaccent" field
- Parameters: name (String) - series name with diacritics, options (Hash) - additional options
- Returns: Hash - search results
- Usage: Searching for non-English series names

#### `#search_by_alias(alias_name, options = {})`
Search for series by alias/alternate names
- Parameters: alias_name (String) - the alias to search for, options (Hash) - additional options
- Returns: Hash - search results
- Usage: Finding series by common nicknames or shortened names

#### `#search_by_type(type, options = {})`
Search for series by type, focusing on "Release group series"
- Parameters: type (String) - the series type, options (Hash) - additional options
- Returns: Hash - search results
- Usage: Filtering to specific series types like album rankings

#### `#search_by_tag(tag, options = {})`
Search for series by associated tags
- Parameters: tag (String) - the tag to search for, options (Hash) - additional options
- Returns: Hash - search results
- Usage: Finding series tagged with "ranking", "best-of", etc.

#### `#search_by_comment(comment, options = {})`
Search for series by disambiguation comment
- Parameters: comment (String) - the disambiguation comment, options (Hash) - additional options
- Returns: Hash - search results
- Usage: Distinguishing between similar series names

### Browse Methods

#### `#browse_series_with_release_groups(series_mbid, options = {})`
Browse series details with release group relationships using MusicBrainz browse API
- Parameters: series_mbid (String) - the series MusicBrainz ID, options (Hash) - additional options
- Returns: Hash - browse results with release group relationships and ordering information
- Usage: Getting complete ranked list with release groups and their positions
- API: Uses `/ws/2/series/{mbid}?inc=release-group-rels`

### Convenience Methods

#### `#search_release_group_series(name = nil, options = {})`
Search specifically for "Release group series" type, optionally filtered by name
- Parameters: name (String, optional) - series name filter, options (Hash) - additional options
- Returns: Hash - search results filtered to release group series
- Usage: Most common use case for finding music album rankings

#### `#search_by_name_and_type(name, type, options = {})`
Combined search by both name and type
- Parameters: name (String) - series name, type (String) - series type, options (Hash) - additional options
- Returns: Hash - search results matching both criteria
- Usage: Precise searches when you know both name and type

### Inherited Methods

#### `#search(query, options = {})`
Perform general search with custom Lucene syntax
- Parameters: query (String) - Lucene query string, options (Hash) - additional options
- Returns: Hash - search results
- Usage: Complex queries with custom syntax

#### `#search_with_criteria(criteria, options = {})`
Build complex queries with multiple search criteria
- Parameters: criteria (Hash) - field/value pairs for search, options (Hash) - additional options
- Returns: Hash - search results
- Usage: Multi-field searches with validation

#### `#find_by_mbid(mbid, options = {})`
Find series by MusicBrainz ID
- Parameters: mbid (String) - the series MBID, options (Hash) - additional options
- Returns: Hash - search results
- Usage: Direct lookup when you have the MBID

## Entity Configuration

### `#entity_type`
Returns "series" - the MusicBrainz entity type for API requests

### `#mbid_field`
Returns "sid" - the MBID field name for series (series ID)

### `#available_fields`
Returns available search fields: `["series", "seriesaccent", "alias", "comment", "sid", "tag", "type"]`

## Response Processing

### Browse Response Transformation
The class includes custom `process_browse_response` method that:
- Transforms single series object from browse API to match search API format
- Creates consistent response structure with `count`, `offset`, `results` array
- Preserves relationship data with ordering keys for rankings

## Error Handling
- Custom error handling for browse operations with proper metadata structure
- Inherits standard search error handling from BaseSearch
- Validates MBID format for browse operations
- Graceful handling of network errors and API failures

## Dependencies
- Music::Musicbrainz::BaseClient for HTTP requests
- Music::Musicbrainz::Search::BaseSearch parent class
- Music::Musicbrainz exception classes for error handling
- Time class for timestamp generation

## Usage Examples

```ruby
# Initialize
series_search = Music::Musicbrainz::Search::SeriesSearch.new(client)

# Find ranking lists
results = series_search.search_by_name("Vice's 100 Greatest Albums")
results = series_search.search_release_group_series("Rolling Stone")

# Get detailed ranking with release groups
details = series_search.browse_series_with_release_groups("28cbc99a-875f-4139-b8b0-f1dd520ec62c")
# Returns release groups with ordering-key for position in ranking

# Complex search
results = series_search.search_with_criteria({
  type: "Release group series",
  tag: "ranking"
})
```

## API Integration Patterns

### Search vs Browse APIs
- **Search API** (`/ws/2/series/?query=...`): Used for finding series by various criteria
- **Browse API** (`/ws/2/series/{mbid}?inc=release-group-rels`): Used for getting detailed relationships

### Response Formats
- **Search responses**: Returns array of series in `results` field
- **Browse responses**: Returns single series object, transformed to match search format
- **Relationship data**: Includes `ordering-key` field for ranking positions

## Key Features
- Comprehensive search functionality across all series fields
- Specialized support for "Release group series" (music rankings)
- Browse API integration for complete relationship data
- Response format consistency between search and browse operations
- Robust error handling and validation
- Full pagination support
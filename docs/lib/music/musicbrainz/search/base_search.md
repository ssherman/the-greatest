# Music::Musicbrainz::Search::BaseSearch

## Summary
Abstract base class providing common search functionality for all MusicBrainz entity search classes, including MBID validation, query building, and error handling.

## Abstract Methods
Subclasses must implement these methods:

### `#entity_type`
Returns the entity type for the search
- Returns: String - Entity type (e.g., "artist", "release-group")

### `#mbid_field`
Returns the MBID field name for the entity
- Returns: String - MBID field name (e.g., "arid", "rgid")

### `#available_fields`
Returns the list of searchable fields for the entity
- Returns: Array<String> - List of available search fields

## Public Methods

### `#initialize(client)`
Creates a new search instance
- Parameters: client (Music::Musicbrainz::BaseClient) - HTTP client

### `#find_by_mbid(mbid, options = {})`
Finds an entity by its MusicBrainz ID
- Parameters:
  - mbid (String) - MusicBrainz ID
  - options (Hash) - Additional search options
- Returns: Hash - Search results
- Raises: Music::Musicbrainz::QueryError - If MBID is invalid

### `#search_by_field(field, value, options = {})`
Searches for entities by a specific field
- Parameters:
  - field (String) - Search field name
  - value (String) - Search value
  - options (Hash) - Additional search options
- Returns: Hash - Search results
- Raises: Music::Musicbrainz::QueryError - If field is invalid

### `#search(query, options = {})`
Performs a general search with custom Lucene query
- Parameters:
  - query (String) - Lucene search query
  - options (Hash) - Additional search options
- Returns: Hash - Search results

### `#search_with_criteria(criteria, options = {})`
Builds a complex query with multiple criteria
- Parameters:
  - criteria (Hash) - Search criteria (field: value pairs)
  - options (Hash) - Additional search options
- Returns: Hash - Search results
- Raises: Music::Musicbrainz::QueryError - If criteria are invalid

## Protected Methods

### `#build_field_query(field, value)`
Builds a Lucene field query with proper escaping
- Parameters:
  - field (String) - Field name
  - value (String) - Field value
- Returns: String - Escaped Lucene query

### `#build_search_params(query, options)`
Builds search parameters for API request
- Parameters:
  - query (String) - Search query
  - options (Hash) - Additional options
- Returns: Hash - API parameters

### `#process_search_response(response)`
Processes the search response
- Parameters: response (Hash) - Raw API response
- Returns: Hash - Processed response

### `#handle_search_error(error, query, options)`
Handles search errors gracefully
- Parameters:
  - error (Exception) - The error that occurred
  - query (String) - Original search query
  - options (Hash) - Search options
- Returns: Hash - Error response

### `#validate_mbid!(mbid)`
Validates MusicBrainz ID format
- Parameters: mbid (String) - MBID to validate
- Raises: Music::Musicbrainz::QueryError - If MBID is invalid

### `#validate_search_params!(params)`
Validates search parameters
- Parameters: params (Hash) - Parameters to validate
- Raises: Music::Musicbrainz::QueryError - If parameters are invalid

### `#escape_lucene_query(query)`
Escapes special characters in Lucene queries
- Parameters: query (String) - Query to escape
- Returns: String - Escaped query

## Lucene Query Escaping
The class handles escaping of special Lucene characters:
- Backslashes (`\`) - Escaped as `\\`
- Spaces (` `) - Escaped as `\ `
- Colons (`:`) - Escaped as `\:`
- Hyphens (`-`) - Escaped as `\-`

## Response Structure
```ruby
{
  success: true/false,
  data: {
    # Raw MusicBrainz API response
  },
  errors: ["Error message"],
  metadata: {
    entity_type: "artist",
    query: "name:Beatles",
    endpoint: "artist"
  }
}
```

## Usage
```ruby
# Subclass implementation example
class ArtistSearch < BaseSearch
  def entity_type
    "artist"
  end
  
  def mbid_field
    "arid"
  end
  
  def available_fields
    %w[name arid alias tag type country gender]
  end
end

# Usage
client = Music::Musicbrainz::BaseClient.new(config)
search = ArtistSearch.new(client)

# Find by MBID
results = search.find_by_mbid("b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")

# Search by field
results = search.search_by_field("name", "The Beatles")

# Complex search
results = search.search_with_criteria({
  name: "The Beatles",
  type: "Group",
  country: "GB"
})
```

## Error Handling
- **Invalid MBIDs**: Validates UUID format
- **Invalid Fields**: Checks against available_fields
- **Query Errors**: Provides helpful error messages
- **Network Errors**: Graceful degradation with error responses

## Dependencies
- Music::Musicbrainz::BaseClient for HTTP requests
- Music::Musicbrainz::Exceptions for error handling
- UUID validation for MBID checking 
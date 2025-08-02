# Music::Musicbrainz::Search::ArtistSearch

## Summary
Search class for finding artists in the MusicBrainz database by name, MBID, aliases, tags, type, country, and gender.

## Entity Information
- **Entity Type**: "artist"
- **MBID Field**: "arid"
- **API Endpoint**: `/ws/2/artist/`

## Available Search Fields
- `name` - Artist name
- `arid` - Artist MBID
- `alias` - Artist aliases
- `tag` - Tags associated with artist
- `type` - Artist type (Person, Group, Orchestra, Choir, Character)
- `country` - ISO country code
- `gender` - Gender (male, female, other)
- `begin` - Begin date
- `end` - End date
- `area` - Area information
- `sortname` - Sort name
- `comment` - Disambiguation comment

## Public Methods

### Basic Search Methods

#### `#search_by_name(name, options = {})`
Searches for artists by name
- Parameters:
  - name (String) - Artist name to search for
  - options (Hash) - Additional search options (limit, offset)
- Returns: Hash - Search results

#### `#find_by_mbid(mbid, options = {})`
Searches for artist by MusicBrainz ID
- Parameters:
  - mbid (String) - Artist MBID (UUID format)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_alias(alias_name, options = {})`
Searches for artists by alias
- Parameters:
  - alias_name (String) - Artist alias
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_tag(tag, options = {})`
Searches for artists by tag
- Parameters:
  - tag (String) - Tag to search for
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_type(type, options = {})`
Searches for artists by type
- Parameters:
  - type (String) - Artist type (Person, Group, Orchestra, Choir, Character)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_country(country_code, options = {})`
Searches for artists by country
- Parameters:
  - country_code (String) - ISO country code
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_gender(gender, options = {})`
Searches for artists by gender
- Parameters:
  - gender (String) - Gender (male, female, other)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

### Combined Search Methods

#### `#search_with_criteria(criteria, options = {})`
Searches for artists using multiple criteria
- Parameters:
  - criteria (Hash) - Search criteria with field names as keys (name:, type:, country:, etc.)
  - options (Hash) - Additional search options (limit, offset)
- Returns: Hash - Search results

#### `#search(query, options = {})`
Performs a general search with custom Lucene syntax
- Parameters:
  - query (String) - Raw Lucene query string
  - options (Hash) - Additional search options
- Returns: Hash - Search results

## Usage Examples

```ruby
# Create search instance (client is optional - defaults to new BaseClient)
artist_search = Music::Musicbrainz::Search::ArtistSearch.new

# Or with custom client
client = Music::Musicbrainz::BaseClient.new
artist_search = Music::Musicbrainz::Search::ArtistSearch.new(client)

# Search by name
results = artist_search.search_by_name("The Beatles")
if results[:success]
  artists = results[:data]["artists"]
  puts "Found #{artists.length} artists"
end

# Search by MBID
results = artist_search.find_by_mbid("b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")
if results[:success]
  artist = results[:data]["artists"].first
  puts "Found: #{artist['name']}"
end

# Search by type
results = artist_search.search_by_type("Group")
if results[:success]
  groups = results[:data]["artists"]
  puts "Found #{groups.length} groups"
end

# Search by country
results = artist_search.search_by_country("GB")
if results[:success]
  uk_artists = results[:data]["artists"]
  puts "Found #{uk_artists.length} UK artists"
end

# Complex search with multiple criteria
results = artist_search.search_with_criteria({
  name: "Beatles",
  type: "Group",
  country: "GB"
})

# Raw Lucene query
results = artist_search.search("name:Beatles AND type:Group")
```

## Response Data Structure
```ruby
{
  success: true,
  data: {
    "count" => 1,
    "offset" => 0,
    "artists" => [
      {
        "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
        "name" => "The Beatles",
        "sort-name" => "Beatles, The",
        "type" => "Group",
        "country" => "GB",
        "gender" => nil,
        "score" => "100"
      }
    ]
  },
  errors: [],
  metadata: {
    entity_type: "artist",
    query: "name:The\\ Beatles",
    endpoint: "artist"
  }
}
```

## Common Use Cases
- **Artist Discovery**: Find artists by name or alias
- **Genre Exploration**: Search artists by tags
- **Geographic Filtering**: Find artists by country
- **Type Filtering**: Distinguish between individuals and groups
- **MBID Lookup**: Get artist details by MusicBrainz ID
- **Complex Queries**: Combine multiple search criteria
- **Raw Lucene Queries**: Use advanced search syntax

## Error Handling
- **Invalid MBIDs**: Validates UUID format
- **Invalid Fields**: Checks against available search fields
- **Network Errors**: Graceful degradation with error responses
- **Query Errors**: Helpful error messages for invalid queries

## Dependencies
- Music::Musicbrainz::Search::BaseSearch for common functionality
- Music::Musicbrainz::BaseClient for HTTP requests (auto-instantiated if not provided)
- Music::Musicbrainz::Exceptions for error handling

## Notes
- The ArtistSearch class inherits from BaseSearch which provides common search functionality
- Client instantiation is optional - if not provided, a default BaseClient will be created
- All search methods return a standardized response hash with :success, :data, :errors, and :metadata keys
- MBID searches use the `find_by_mbid` method which validates UUID format
- Complex searches can be performed using `search_with_criteria` or raw Lucene queries with `search` 
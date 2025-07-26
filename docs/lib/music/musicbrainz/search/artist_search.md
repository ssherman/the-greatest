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

## Public Methods

### Basic Search Methods

#### `#search_by_name(name, options = {})`
Searches for artists by name
- Parameters:
  - name (String) - Artist name to search for
  - options (Hash) - Additional search options (limit, offset)
- Returns: Hash - Search results

#### `#search_by_mbid(mbid, options = {})`
Searches for artist by MusicBrainz ID
- Parameters:
  - mbid (String) - Artist MBID
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

#### `#search_by_name_and_type(name, type, options = {})`
Searches for artists by name and type
- Parameters:
  - name (String) - Artist name
  - type (String) - Artist type
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_name_and_country(name, country_code, options = {})`
Searches for artists by name and country
- Parameters:
  - name (String) - Artist name
  - country_code (String) - ISO country code
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_artist_groups(artist_mbid, options = {})`
Searches for groups associated with an artist
- Parameters:
  - artist_mbid (String) - Artist MBID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

## Usage Examples

```ruby
client = Music::Musicbrainz::BaseClient.new(config)
artist_search = Music::Musicbrainz::Search::ArtistSearch.new(client)

# Search by name
results = artist_search.search_by_name("The Beatles")
if results[:success]
  artists = results[:data]["artists"]
  puts "Found #{artists.length} artists"
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

# Complex search
results = artist_search.search_with_criteria({
  name: "Beatles",
  type: "Group",
  country: "GB"
})
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

## Error Handling
- **Invalid MBIDs**: Validates UUID format
- **Invalid Fields**: Checks against available search fields
- **Network Errors**: Graceful degradation with error responses
- **Query Errors**: Helpful error messages for invalid queries

## Dependencies
- Music::Musicbrainz::Search::BaseSearch for common functionality
- Music::Musicbrainz::BaseClient for HTTP requests
- Music::Musicbrainz::Exceptions for error handling 
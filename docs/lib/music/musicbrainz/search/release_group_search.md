# Music::Musicbrainz::Search::ReleaseGroupSearch

## Summary
Search class for finding release groups (albums) in the MusicBrainz database by title, artist, type, tags, country, and date.

## Entity Information
- **Entity Type**: "release-group"
- **MBID Field**: "rgid"
- **API Endpoint**: `/ws/2/release-group/`

## Available Search Fields
- `title` - Release group title
- `rgid` - Release group MBID
- `arid` - Artist MBID
- `artist` - Artist name
- `type` - Release group type (Album, Single, EP, Compilation, Soundtrack, etc.)
- `tag` - Tags associated with release group
- `country` - ISO country code
- `date` - Release date (YYYY, YYYY-MM, or YYYY-MM-DD)
- `first_release_date` - First release date

## Public Methods

### Basic Search Methods

#### `#search_by_title(title, options = {})`
Searches for release groups by title
- Parameters:
  - title (String) - Release group title
  - options (Hash) - Additional search options (limit, offset)
- Returns: Hash - Search results

#### `#search_by_artist_mbid(artist_mbid, options = {})`
Searches for release groups by artist MBID
- Parameters:
  - artist_mbid (String) - Artist MusicBrainz ID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_artist_name(artist_name, options = {})`
Searches for release groups by artist name
- Parameters:
  - artist_name (String) - Artist name
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_tag(tag, options = {})`
Searches for release groups by tag
- Parameters:
  - tag (String) - Tag to search for
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_type(type, options = {})`
Searches for release groups by type
- Parameters:
  - type (String) - Release group type (Album, Single, EP, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_country(country_code, options = {})`
Searches for release groups by country
- Parameters:
  - country_code (String) - ISO country code
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_date(date, options = {})`
Searches for release groups by date
- Parameters:
  - date (String) - Release date (YYYY, YYYY-MM, or YYYY-MM-DD)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_first_release_date(date, options = {})`
Searches for release groups by first release date
- Parameters:
  - date (String) - First release date
  - options (Hash) - Additional search options
- Returns: Hash - Search results

### Combined Search Methods

#### `#search_by_artist_and_title(artist_name, title, options = {})`
Searches for release groups by artist name and title
- Parameters:
  - artist_name (String) - Artist name
  - title (String) - Release group title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_artist_mbid_and_title(artist_mbid, title, options = {})`
Searches for release groups by artist MBID and title
- Parameters:
  - artist_mbid (String) - Artist MBID
  - title (String) - Release group title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_artist_albums(artist_mbid, options = {})`
Searches for albums by a specific artist
- Parameters:
  - artist_mbid (String) - Artist MBID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

## Usage Examples

```ruby
client = Music::Musicbrainz::BaseClient.new(config)
rg_search = Music::Musicbrainz::Search::ReleaseGroupSearch.new(client)

# Search by title
results = rg_search.search_by_title("Abbey Road")
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} albums"
end

# Search by artist and title
results = rg_search.search_by_artist_and_title("The Beatles", "Abbey Road")
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} matching albums"
end

# Search artist's albums
results = rg_search.search_artist_albums("b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} albums by this artist"
end

# Search by type
results = rg_search.search_by_type("Album")
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} albums"
end

# Complex search
results = rg_search.search_with_criteria({
  title: "Abbey Road",
  arid: "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
  type: "Album",
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
    "release-groups" => [
      {
        "id" => "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d",
        "title" => "Abbey Road",
        "type" => "Album",
        "primary-type" => "Album",
        "artist-credit" => [
          {
            "name" => "The Beatles",
            "artist" => {
              "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
              "name" => "The Beatles"
            }
          }
        ],
        "first-release-date" => "1969-09-26",
        "score" => "100"
      }
    ]
  },
  errors: [],
  metadata: {
    entity_type: "release-group",
    query: "title:Abbey\\ Road",
    endpoint: "release-group"
  }
}
```

## Common Use Cases
- **Album Discovery**: Find albums by title or artist
- **Artist Discography**: Get all albums by a specific artist
- **Genre Exploration**: Search albums by tags
- **Release Date Filtering**: Find albums by release date
- **Type Filtering**: Distinguish between albums, singles, EPs, etc.
- **Geographic Filtering**: Find albums by country

## Error Handling
- **Invalid MBIDs**: Validates UUID format
- **Invalid Fields**: Checks against available search fields
- **Network Errors**: Graceful degradation with error responses
- **Query Errors**: Helpful error messages for invalid queries

## Dependencies
- Music::Musicbrainz::Search::BaseSearch for common functionality
- Music::Musicbrainz::BaseClient for HTTP requests
- Music::Musicbrainz::Exceptions for error handling 
# Music::Musicbrainz::Search::ReleaseGroupSearch

## Summary
Search class for finding release groups (albums) in the MusicBrainz database by title, artist, type, tags, country, and date.

## Entity Information
- **Entity Type**: "release-group"
- **MBID Field**: "rgid"
- **API Endpoint**: `/ws/2/release-group/`

## Available Search Fields
- `alias` - Any alias attached to the release group (diacritics ignored)
- `arid` - Artist MBID (any of the release group artists)
- `artist` - Combined credited artist name including join phrases (e.g. "Artist X feat.")
- `artistname` - Name of any of the release group artists
- `comment` - Disambiguation comment
- `creditname` - Credited name of any artist on this particular release group
- `firstreleasedate` - Release date of the earliest release in this group (e.g. "1980-01-22")
- `primarytype` - Primary type of the release group (Album, Single, EP, etc.)
- `reid` - MBID of any release in the release group
- `release` - Title of any release in the release group
- `releasegroup` - Release group title (diacritics ignored)
- `releasegroupaccent` - Release group title (with specified diacritics)
- `releases` - Number of releases in the release group
- `rgid` - Release group MBID
- `secondarytype` - Any secondary type (Compilation, Live, Soundtrack, etc.)
- `status` - Status of any release in the release group
- `tag` - Tags attached to the release group
- `type` - Legacy release group type field
- `title` - Release group title (alias for releasegroup)
- `country` - ISO country code (extended field)
- `date` - Release date (extended field)

## Public Methods

### Basic Search Methods

#### `#find_by_mbid(mbid, options = {})`
Searches for release group by MusicBrainz ID
- Parameters:
  - mbid (String) - Release group MBID (UUID format)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

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

#### `#search_by_primary_type(primary_type, options = {})`
Searches for release groups by primary type
- Parameters:
  - primary_type (String) - Primary type (Album, Single, EP, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_secondary_type(secondary_type, options = {})`
Searches for release groups by secondary type
- Parameters:
  - secondary_type (String) - Secondary type (Compilation, Live, Soundtrack, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_alias(alias_name, options = {})`
Searches for release groups by alias
- Parameters:
  - alias_name (String) - Alias to search for
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_credit_name(credit_name, options = {})`
Searches for release groups by credited artist name
- Parameters:
  - credit_name (String) - Credited artist name
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_release_mbid(release_mbid, options = {})`
Searches for release groups by release MBID
- Parameters:
  - release_mbid (String) - Release MBID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_release_title(release_title, options = {})`
Searches for release groups by release title
- Parameters:
  - release_title (String) - Release title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_release_count(count, options = {})`
Searches for release groups by number of releases
- Parameters:
  - count (Integer) - Number of releases
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

#### `#search_artist_albums(artist_mbid, filters = {}, options = {})`
Searches for albums by a specific artist with optional filters
- Parameters:
  - artist_mbid (String) - Artist MBID
  - filters (Hash) - Additional filters (type:, country:, date:, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_primary_albums_only(artist_mbid = nil, options = {})`
Searches for official primary albums only (excludes compilations, soundtracks, live albums, bootlegs, etc.)
- Parameters:
  - artist_mbid (String, nil) - Optional artist MBID to filter by
  - options (Hash) - Additional search options
- Returns: Hash - Search results
- Note: This method finds albums with primarytype:Album, no secondary types, and status:Official

#### `#search_with_criteria(criteria, options = {})`
Searches for release groups using multiple criteria
- Parameters:
  - criteria (Hash) - Search criteria with field names as keys (title:, arid:, type:, etc.)
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
rg_search = Music::Musicbrainz::Search::ReleaseGroupSearch.new

# Or with custom client
client = Music::Musicbrainz::BaseClient.new
rg_search = Music::Musicbrainz::Search::ReleaseGroupSearch.new(client)

# Search by title
results = rg_search.search_by_title("Abbey Road")
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} albums"
end

# Search by MBID
results = rg_search.find_by_mbid("b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d")
if results[:success]
  album = results[:data]["release-groups"].first
  puts "Found: #{album['title']}"
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

# Search artist's albums with filters
results = rg_search.search_artist_albums("b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d", {
  type: "Album",
  country: "GB"
})
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} UK albums by this artist"
end

# Search by type
results = rg_search.search_by_type("Album")
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} albums"
end

# Search by primary type (more specific than legacy type field)
results = rg_search.search_by_primary_type("Album")
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} albums"
end

# Search by secondary type
results = rg_search.search_by_secondary_type("Compilation")
if results[:success]
  compilations = results[:data]["release-groups"]
  puts "Found #{compilations.length} compilation albums"
end

# Search for official primary albums only (excludes compilations, soundtracks, bootlegs, etc.)
# This is perfect for finding official studio albums
results = rg_search.search_primary_albums_only
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} official primary albums"
end

# Search for official primary albums by a specific artist
results = rg_search.search_primary_albums_only("b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} official primary albums by this artist"
end

# Search by alias
results = rg_search.search_by_alias("White Album")
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} albums with this alias"
end

# Search by release count (albums with specific number of releases)
results = rg_search.search_by_release_count(1)
if results[:success]
  albums = results[:data]["release-groups"]
  puts "Found #{albums.length} albums with exactly 1 release"
end

# Complex search with multiple criteria including new fields
results = rg_search.search_with_criteria({
  title: "Abbey Road",
  arid: "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
  primarytype: "Album",
  country: "GB"
})

# Raw Lucene query for official primary albums only
results = rg_search.search("primarytype:Album AND -secondarytype:* AND status:Official")

# Raw Lucene query combining multiple criteria
results = rg_search.search("title:\"Abbey Road\" AND artist:\"The Beatles\" AND primarytype:Album")
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
- **Album Discovery**: Find albums by title, artist, or alias
- **Artist Discography**: Get all albums by a specific artist
- **Official Primary Albums Only**: Find official studio albums excluding compilations, soundtracks, live albums, bootlegs
- **Genre Exploration**: Search albums by tags
- **Release Date Filtering**: Find albums by release date or first release date
- **Type Filtering**: Distinguish between albums, singles, EPs using primary/secondary types
- **Release Analysis**: Search by number of releases or specific release titles
- **Credit Analysis**: Find albums by credited artist names
- **Geographic Filtering**: Find albums by country
- **MBID Lookup**: Get release group details by MusicBrainz ID or release MBID
- **Complex Queries**: Combine multiple search criteria including new fields
- **Raw Lucene Queries**: Use advanced search syntax with all available fields

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
- The ReleaseGroupSearch class inherits from BaseSearch which provides common search functionality
- Client instantiation is optional - if not provided, a default BaseClient will be created
- All search methods return a standardized response hash with :success, :data, :errors, and :metadata keys
- MBID searches use the `find_by_mbid` method which validates UUID format
- Complex searches can be performed using `search_with_criteria` or raw Lucene queries with `search`
- The `search_artist_albums` method supports optional filters for more precise searches 
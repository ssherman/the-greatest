# Music::Musicbrainz::Search::WorkSearch

## Summary
Search class for finding musical works (compositions) in the MusicBrainz database by title, artist, ISWC, language, type, and other metadata.

## Entity Information
- **Entity Type**: "work"
- **MBID Field**: "wid"
- **API Endpoint**: `/ws/2/work/`

## Available Search Fields
- `work` - Work title
- `workaccent` - Work title with diacritics
- `wid` - Work MBID
- `alias` - Work aliases
- `arid` - Artist MBID (composer/lyricist)
- `artist` - Artist name (composer/lyricist)
- `iswc` - International Standard Musical Work Code
- `tag` - Tags associated with work
- `type` - Work type (song, symphony, opera, etc.)
- `comment` - Disambiguation comment
- `lang` - ISO 639-3 language code
- `recording` - Related recording title
- `recording_count` - Number of recordings
- `rid` - Recording MBID

## Public Methods

### Basic Search Methods

#### `#find_by_mbid(mbid, options = {})`
Searches for work by MusicBrainz ID
- Parameters:
  - mbid (String) - Work MBID (UUID format)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_title(title, options = {})`
Searches for works by title
- Parameters:
  - title (String) - Work title
  - options (Hash) - Additional search options (limit, offset)
- Returns: Hash - Search results

#### `#search_by_title_with_accent(title, options = {})`
Searches for works by title with diacritics preserved
- Parameters:
  - title (String) - Work title with diacritics
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_artist_mbid(artist_mbid, options = {})`
Searches for works by artist MBID
- Parameters:
  - artist_mbid (String) - Artist MusicBrainz ID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_artist_name(artist_name, options = {})`
Searches for works by artist name
- Parameters:
  - artist_name (String) - Artist name
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_alias(alias_name, options = {})`
Searches for works by alias
- Parameters:
  - alias_name (String) - Work alias
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_iswc(iswc, options = {})`
Searches for works by ISWC
- Parameters:
  - iswc (String) - International Standard Musical Work Code
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_tag(tag, options = {})`
Searches for works by tag
- Parameters:
  - tag (String) - Tag to search for
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_type(type, options = {})`
Searches for works by type
- Parameters:
  - type (String) - Work type (song, symphony, opera, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_language(language_code, options = {})`
Searches for works by language code
- Parameters:
  - language_code (String) - ISO 639-3 language code
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_recording_title(recording_title, options = {})`
Searches for works by related recording title
- Parameters:
  - recording_title (String) - Recording title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_recording_mbid(recording_mbid, options = {})`
Searches for works by related recording MBID
- Parameters:
  - recording_mbid (String) - Recording MBID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_recording_count(count, options = {})`
Searches for works by number of recordings
- Parameters:
  - count (Integer) - Number of recordings
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_comment(comment, options = {})`
Searches for works by disambiguation comment
- Parameters:
  - comment (String) - Disambiguation comment
  - options (Hash) - Additional search options
- Returns: Hash - Search results

### Combined Search Methods

#### `#search_by_artist_and_title(artist_name, title, options = {})`
Searches for works by artist name and title
- Parameters:
  - artist_name (String) - Artist name
  - title (String) - Work title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_artist_mbid_and_title(artist_mbid, title, options = {})`
Searches for works by artist MBID and title
- Parameters:
  - artist_mbid (String) - Artist MBID
  - title (String) - Work title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_artist_works(artist_mbid, filters = {}, options = {})`
Searches for works by a specific artist with optional filters
- Parameters:
  - artist_mbid (String) - Artist MBID
  - filters (Hash) - Additional filters (type:, lang:, iswc:, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_recording_count_range(min_count, max_count, options = {})`
Searches for works with recording count in a range
- Parameters:
  - min_count (Integer) - Minimum number of recordings
  - max_count (Integer) - Maximum number of recordings
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_with_criteria(criteria, options = {})`
Searches for works using multiple criteria
- Parameters:
  - criteria (Hash) - Search criteria with field names as keys (work:, arid:, type:, etc.)
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
work_search = Music::Musicbrainz::Search::WorkSearch.new

# Or with custom client
client = Music::Musicbrainz::BaseClient.new
work_search = Music::Musicbrainz::Search::WorkSearch.new(client)

# Search by title
results = work_search.search_by_title("Yesterday")
if results[:success]
  works = results[:data]["works"]
  puts "Found #{works.length} works"
end

# Search by MBID
results = work_search.find_by_mbid("10c1a66a-8166-32ec-a00f-540f111ce7a3")
if results[:success]
  work = results[:data]["works"].first
  puts "Found: #{work['title']}"
end

# Search by artist and title
results = work_search.search_by_artist_and_title("Paul McCartney", "Yesterday")
if results[:success]
  works = results[:data]["works"]
  puts "Found #{works.length} matching works"
end

# Search by ISWC
results = work_search.search_by_iswc("T-010.140.236-1")
if results[:success]
  works = results[:data]["works"]
  puts "Found #{works.length} works with this ISWC"
end

# Search by type
results = work_search.search_by_type("song")
if results[:success]
  songs = results[:data]["works"]
  puts "Found #{songs.length} songs"
end

# Search by language
results = work_search.search_by_language("eng")
if results[:success]
  english_works = results[:data]["works"]
  puts "Found #{english_works.length} English works"
end

# Search artist's works with filters
results = work_search.search_artist_works("ba550d0e-adac-4208-b99b-7a5f8d7bcf31", {
  type: "song",
  lang: "eng"
})
if results[:success]
  works = results[:data]["works"]
  puts "Found #{works.length} English songs by this artist"
end

# Search by recording count range
results = work_search.search_by_recording_count_range(10, 100)
if results[:success]
  works = results[:data]["works"]
  puts "Found #{works.length} works with 10-100 recordings"
end

# Complex search with multiple criteria
results = work_search.search_with_criteria({
  work: "Yesterday",
  arid: "ba550d0e-adac-4208-b99b-7a5f8d7bcf31",
  iswc: "T-010.140.236-1"
})

# Raw Lucene query
results = work_search.search("work:Yesterday AND artist:\"Paul McCartney\"")
```

## Response Data Structure
```ruby
{
  success: true,
  data: {
    "count" => 1,
    "offset" => 0,
    "works" => [
      {
        "id" => "10c1a66a-8166-32ec-a00f-540f111ce7a3",
        "title" => "Yesterday",
        "type" => "Song",
        "iswcs" => ["T-010.140.236-1"],
        "language" => "eng",
        "relations" => [
          {
            "type" => "composer",
            "direction" => "backward",
            "artist" => {
              "id" => "ba550d0e-adac-4208-b99b-7a5f8d7bcf31",
              "name" => "Paul McCartney",
              "sort-name" => "McCartney, Paul"
            }
          }
        ],
        "score" => "100"
      }
    ]
  },
  errors: [],
  metadata: {
    entity_type: "work",
    query: "work:Yesterday",
    endpoint: "work"
  }
}
```

## Common Use Cases
- **Composition Discovery**: Find musical works by title or composer
- **ISWC Lookup**: Find works by International Standard Musical Work Code
- **Composer Catalog**: Get all works by a specific composer
- **Language Filtering**: Find works by language
- **Type Filtering**: Distinguish between songs, symphonies, operas, etc.
- **Recording Relationships**: Find works through their recordings
- **MBID Lookup**: Get work details by MusicBrainz ID
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
- The WorkSearch class inherits from BaseSearch which provides common search functionality
- Client instantiation is optional - if not provided, a default BaseClient will be created
- All search methods return a standardized response hash with :success, :data, :errors, and :metadata keys
- MBID searches use the `find_by_mbid` method which validates UUID format
- Complex searches can be performed using `search_with_criteria` or raw Lucene queries with `search`
- Recording count ranges use Lucene range syntax: `[min TO max]` 
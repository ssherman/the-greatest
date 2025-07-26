# Music::Musicbrainz::Search::RecordingSearch

## Summary
Search class for finding recordings (songs/tracks) in the MusicBrainz database by title, artist, ISRC, duration, release group, and other metadata.

## Entity Information
- **Entity Type**: "recording"
- **MBID Field**: "rid"
- **API Endpoint**: `/ws/2/recording/`

## Available Search Fields
- `title` - Recording title
- `rid` - Recording MBID
- `arid` - Artist MBID
- `artist` - Artist name
- `isrc` - International Standard Recording Code
- `tag` - Tags associated with recording
- `dur` - Duration in milliseconds
- `length` - Duration in seconds
- `rgid` - Release group MBID
- `release` - Release title
- `country` - ISO country code
- `date` - Release date

## Public Methods

### Basic Search Methods

#### `#search_by_title(title, options = {})`
Searches for recordings by title
- Parameters:
  - title (String) - Recording title
  - options (Hash) - Additional search options (limit, offset)
- Returns: Hash - Search results

#### `#search_by_artist_mbid(artist_mbid, options = {})`
Searches for recordings by artist MBID
- Parameters:
  - artist_mbid (String) - Artist MusicBrainz ID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_artist_name(artist_name, options = {})`
Searches for recordings by artist name
- Parameters:
  - artist_name (String) - Artist name
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_isrc(isrc, options = {})`
Searches for recordings by ISRC
- Parameters:
  - isrc (String) - International Standard Recording Code
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_tag(tag, options = {})`
Searches for recordings by tag
- Parameters:
  - tag (String) - Tag to search for
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_duration(duration_seconds, options = {})`
Searches for recordings by duration in seconds
- Parameters:
  - duration_seconds (Integer) - Duration in seconds
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_length(duration_seconds, options = {})`
Searches for recordings by duration (alias for search_by_duration)
- Parameters:
  - duration_seconds (Integer) - Duration in seconds
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_release_group_mbid(release_group_mbid, options = {})`
Searches for recordings by release group MBID
- Parameters:
  - release_group_mbid (String) - Release group MBID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_release(release_title, options = {})`
Searches for recordings by release title
- Parameters:
  - release_title (String) - Release title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_country(country_code, options = {})`
Searches for recordings by country
- Parameters:
  - country_code (String) - ISO country code
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_date(date, options = {})`
Searches for recordings by release date
- Parameters:
  - date (String) - Release date (YYYY, YYYY-MM, or YYYY-MM-DD)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

### Combined Search Methods

#### `#search_by_artist_and_title(artist_name, title, options = {})`
Searches for recordings by artist name and title
- Parameters:
  - artist_name (String) - Artist name
  - title (String) - Recording title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_artist_mbid_and_title(artist_mbid, title, options = {})`
Searches for recordings by artist MBID and title
- Parameters:
  - artist_mbid (String) - Artist MBID
  - title (String) - Recording title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_artist_recordings(artist_mbid, options = {})`
Searches for recordings by a specific artist
- Parameters:
  - artist_mbid (String) - Artist MBID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_duration_range(min_seconds, max_seconds, options = {})`
Searches for recordings within a duration range
- Parameters:
  - min_seconds (Integer) - Minimum duration in seconds
  - max_seconds (Integer) - Maximum duration in seconds
  - options (Hash) - Additional search options
- Returns: Hash - Search results

## Usage Examples

```ruby
client = Music::Musicbrainz::BaseClient.new(config)
recording_search = Music::Musicbrainz::Search::RecordingSearch.new(client)

# Search by title
results = recording_search.search_by_title("Yesterday")
if results[:success]
  recordings = results[:data]["recordings"]
  puts "Found #{recordings.length} recordings"
end

# Search by artist and title
results = recording_search.search_by_artist_and_title("The Beatles", "Yesterday")
if results[:success]
  recordings = results[:data]["recordings"]
  puts "Found #{recordings.length} matching recordings"
end

# Search by ISRC
results = recording_search.search_by_isrc("GBUM71402401")
if results[:success]
  recordings = results[:data]["recordings"]
  puts "Found #{recordings.length} recordings with this ISRC"
end

# Search by duration
results = recording_search.search_by_duration(180) # 3 minutes
if results[:success]
  recordings = results[:data]["recordings"]
  puts "Found #{recordings.length} 3-minute recordings"
end

# Search by duration range
results = recording_search.search_by_duration_range(120, 240) # 2-4 minutes
if results[:success]
  recordings = results[:data]["recordings"]
  puts "Found #{recordings.length} recordings between 2-4 minutes"
end

# Search artist's recordings
results = recording_search.search_artist_recordings("b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")
if results[:success]
  recordings = results[:data]["recordings"]
  puts "Found #{recordings.length} recordings by this artist"
end

# Complex search
results = recording_search.search_with_criteria({
  title: "Yesterday",
  arid: "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
  dur: 180
})
```

## Response Data Structure
```ruby
{
  success: true,
  data: {
    "count" => 1,
    "offset" => 0,
    "recordings" => [
      {
        "id" => "f970f1e0-0f9b-4e59-8b12-b5cde6037f4c",
        "title" => "Yesterday",
        "length" => 180000,
        "artist-credit" => [
          {
            "name" => "The Beatles",
            "artist" => {
              "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
              "name" => "The Beatles"
            }
          }
        ],
        "releases" => [
          {
            "id" => "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d",
            "title" => "Help!"
          }
        ],
        "isrcs" => ["GBUM71402401"],
        "score" => "100"
      }
    ]
  },
  errors: [],
  metadata: {
    entity_type: "recording",
    query: "title:Yesterday",
    endpoint: "recording"
  }
}
```

## Common Use Cases
- **Song Discovery**: Find songs by title or artist
- **ISRC Lookup**: Find recordings by International Standard Recording Code
- **Duration Filtering**: Find songs by length or duration range
- **Artist Discography**: Get all recordings by a specific artist
- **Release Group Tracks**: Find all tracks on a specific album
- **Genre Exploration**: Search recordings by tags

## Error Handling
- **Invalid MBIDs**: Validates UUID format
- **Invalid Fields**: Checks against available search fields
- **Network Errors**: Graceful degradation with error responses
- **Query Errors**: Helpful error messages for invalid queries

## Dependencies
- Music::Musicbrainz::Search::BaseSearch for common functionality
- Music::Musicbrainz::BaseClient for HTTP requests
- Music::Musicbrainz::Exceptions for error handling 
# Music::Musicbrainz::Search::ReleaseSearch

## Summary
Search class for finding specific releases (physical/digital editions) in the MusicBrainz database by title, artist, format, country, barcode, catalog number, and other detailed metadata.

## Entity Information
- **Entity Type**: "release"
- **MBID Field**: "reid"
- **API Endpoint**: `/ws/2/release/`

## Available Search Fields
- `release` - Release title
- `reid` - Release MBID
- `alias` - Release aliases
- `arid` - Artist MBID
- `artist` - Artist name
- `asin` - Amazon Standard Identification Number
- `barcode` - UPC/EAN barcode
- `catno` - Catalog number
- `comment` - Disambiguation comment
- `country` - ISO country code
- `creditname` - Credit name (how artist is credited)
- `date` - Release date (YYYY, YYYY-MM, or YYYY-MM-DD)
- `discids` - Disc IDs
- `format` - Release format (CD, Vinyl, Digital, etc.)
- `laid` - Label MBID
- `label` - Label name
- `language` - ISO language code
- `mediums` - Number of mediums (discs)
- `packaging` - Packaging type (Jewel Case, Digipak, etc.)
- `primarytype` - Primary release type (Album, Single, EP, etc.)
- `puid` - PUID (deprecated)
- `quality` - Data quality (low, normal, high)
- `rgid` - Release group MBID
- `releasegroup` - Release group name
- `script` - Script (Latin, Cyrillic, etc.)
- `secondarytype` - Secondary release type (Compilation, Soundtrack, etc.)
- `status` - Release status (Official, Promotion, Bootleg, etc.)
- `tag` - Tags associated with release
- `tracks` - Number of tracks

## Public Methods

### Basic Search Methods

#### `#search_by_title(title, options = {})`
Searches for releases by title
- Parameters:
  - title (String) - Release title
  - options (Hash) - Additional search options (limit, offset)
- Returns: Hash - Search results

#### `#search_by_artist_mbid(artist_mbid, options = {})`
Searches for releases by artist MBID
- Parameters:
  - artist_mbid (String) - Artist MusicBrainz ID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_artist_name(artist_name, options = {})`
Searches for releases by artist name
- Parameters:
  - artist_name (String) - Artist name
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_release_group_mbid(release_group_mbid, options = {})`
Searches for releases by release group MBID
- Parameters:
  - release_group_mbid (String) - Release group MBID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_release_group_name(release_group_name, options = {})`
Searches for releases by release group name
- Parameters:
  - release_group_name (String) - Release group name
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_barcode(barcode, options = {})`
Searches for releases by barcode
- Parameters:
  - barcode (String) - UPC/EAN barcode
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_catalog_number(catalog_number, options = {})`
Searches for releases by catalog number
- Parameters:
  - catalog_number (String) - Label catalog number
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_asin(asin, options = {})`
Searches for releases by Amazon ASIN
- Parameters:
  - asin (String) - Amazon Standard Identification Number
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_country(country_code, options = {})`
Searches for releases by country
- Parameters:
  - country_code (String) - ISO country code
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_format(format, options = {})`
Searches for releases by format
- Parameters:
  - format (String) - Release format (CD, Vinyl, Digital, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_label_mbid(label_mbid, options = {})`
Searches for releases by label MBID
- Parameters:
  - label_mbid (String) - Label MBID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_label_name(label_name, options = {})`
Searches for releases by label name
- Parameters:
  - label_name (String) - Label name
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_status(status, options = {})`
Searches for releases by status
- Parameters:
  - status (String) - Release status (Official, Promotion, Bootleg, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_packaging(packaging, options = {})`
Searches for releases by packaging type
- Parameters:
  - packaging (String) - Packaging type (Jewel Case, Digipak, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_primary_type(primary_type, options = {})`
Searches for releases by primary type
- Parameters:
  - primary_type (String) - Primary release type (Album, Single, EP, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_secondary_type(secondary_type, options = {})`
Searches for releases by secondary type
- Parameters:
  - secondary_type (String) - Secondary release type (Compilation, Soundtrack, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_language(language_code, options = {})`
Searches for releases by language code
- Parameters:
  - language_code (String) - ISO language code
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_script(script, options = {})`
Searches for releases by script
- Parameters:
  - script (String) - Script (Latin, Cyrillic, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_date(date, options = {})`
Searches for releases by release date
- Parameters:
  - date (String) - Release date (YYYY, YYYY-MM, or YYYY-MM-DD)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_medium_count(medium_count, options = {})`
Searches for releases by number of mediums
- Parameters:
  - medium_count (Integer) - Number of mediums (discs)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_track_count(track_count, options = {})`
Searches for releases by number of tracks
- Parameters:
  - track_count (Integer) - Number of tracks
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_tag(tag, options = {})`
Searches for releases by tag
- Parameters:
  - tag (String) - Tag to search for
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_alias(alias_name, options = {})`
Searches for releases by alias
- Parameters:
  - alias_name (String) - Release alias
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_comment(comment, options = {})`
Searches for releases by disambiguation comment
- Parameters:
  - comment (String) - Disambiguation comment
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_credit_name(credit_name, options = {})`
Searches for releases by credit name
- Parameters:
  - credit_name (String) - Credit name (how artist is credited)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_quality(quality, options = {})`
Searches for releases by data quality
- Parameters:
  - quality (String) - Data quality (low, normal, high)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_disc_ids(disc_ids, options = {})`
Searches for releases by disc IDs
- Parameters:
  - disc_ids (String) - Disc ID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_puid(puid, options = {})`
Searches for releases by PUID (deprecated)
- Parameters:
  - puid (String) - PUID
  - options (Hash) - Additional search options
- Returns: Hash - Search results

### Combined Search Methods

#### `#search_by_artist_and_title(artist_name, title, options = {})`
Searches for releases by artist name and title
- Parameters:
  - artist_name (String) - Artist name
  - title (String) - Release title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_artist_mbid_and_title(artist_mbid, title, options = {})`
Searches for releases by artist MBID and title
- Parameters:
  - artist_mbid (String) - Artist MBID
  - title (String) - Release title
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_artist_releases(artist_mbid, filters = {}, options = {})`
Searches for releases by a specific artist with optional filters
- Parameters:
  - artist_mbid (String) - Artist MBID
  - filters (Hash) - Additional filters (format:, country:, status:, etc.)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_date_range(start_date, end_date, options = {})`
Searches for releases within a date range
- Parameters:
  - start_date (String) - Start date (YYYY, YYYY-MM, or YYYY-MM-DD)
  - end_date (String) - End date (YYYY, YYYY-MM, or YYYY-MM-DD)
  - options (Hash) - Additional search options
- Returns: Hash - Search results

#### `#search_by_track_count_range(min_tracks, max_tracks, options = {})`
Searches for releases with track count in a range
- Parameters:
  - min_tracks (Integer) - Minimum number of tracks
  - max_tracks (Integer) - Maximum number of tracks
  - options (Hash) - Additional search options
- Returns: Hash - Search results

## Usage Examples

```ruby
client = Music::Musicbrainz::BaseClient.new(config)
release_search = Music::Musicbrainz::Search::ReleaseSearch.new(client)

# Search by title
results = release_search.search_by_title("Abbey Road")
if results[:success]
  releases = results[:data]["releases"]
  puts "Found #{releases.length} releases"
end

# Search by barcode
results = release_search.search_by_barcode("077774644020")
if results[:success]
  releases = results[:data]["releases"]
  puts "Found #{releases.length} releases with this barcode"
end

# Search by catalog number
results = release_search.search_by_catalog_number("PCS 7088")
if results[:success]
  releases = results[:data]["releases"]
  puts "Found #{releases.length} releases with this catalog number"
end

# Search by format
results = release_search.search_by_format("CD")
if results[:success]
  cds = results[:data]["releases"]
  puts "Found #{cds.length} CD releases"
end

# Search by country
results = release_search.search_by_country("GB")
if results[:success]
  uk_releases = results[:data]["releases"]
  puts "Found #{uk_releases.length} UK releases"
end

# Search by status
results = release_search.search_by_status("Official")
if results[:success]
  official_releases = results[:data]["releases"]
  puts "Found #{official_releases.length} official releases"
end

# Search artist's releases with filters
results = release_search.search_artist_releases("b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d", {
  format: "CD",
  country: "GB",
  status: "Official"
})
if results[:success]
  releases = results[:data]["releases"]
  puts "Found #{releases.length} official UK CD releases by this artist"
end

# Search by date range
results = release_search.search_by_date_range("1969", "1970")
if results[:success]
  releases = results[:data]["releases"]
  puts "Found #{releases.length} releases from 1969-1970"
end

# Search by track count range
results = release_search.search_by_track_count_range(10, 20)
if results[:success]
  releases = results[:data]["releases"]
  puts "Found #{releases.length} releases with 10-20 tracks"
end

# Complex search
results = release_search.search_with_criteria({
  release: "Abbey Road",
  arid: "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
  format: "CD",
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
    "releases" => [
      {
        "id" => "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d",
        "title" => "Abbey Road",
        "status" => "Official",
        "packaging" => "Jewel Case",
        "text-representation" => {
          "language" => "eng",
          "script" => "Latn"
        },
        "artist-credit" => [
          {
            "name" => "The Beatles",
            "artist" => {
              "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
              "name" => "The Beatles",
              "sort-name" => "Beatles, The"
            }
          }
        ],
        "release-group" => {
          "id" => "b84ee12a-9f6e-3f70-afb2-5a9c40e74f4d",
          "type" => "Album",
          "primary-type" => "Album"
        },
        "date" => "1969-09-26",
        "country" => "GB",
        "barcode" => "077774644020",
        "asin" => "B000002UAL",
        "label-info" => [
          {
            "catalog-number" => "PCS 7088",
            "label" => {
              "id" => "8f638e84-0b79-4f35-a80c-7b9c73b3d0a1",
              "name" => "Parlophone"
            }
          }
        ],
        "medium-list" => [
          {
            "position" => 1,
            "format" => "CD",
            "disc-list" => [
              {
                "id" => "Wn8eRBtfLDfM0qjYPdxrz.Zjs_U-"
              }
            ],
            "track-count" => 17
          }
        ],
        "score" => "100"
      }
    ]
  },
  errors: [],
  metadata: {
    entity_type: "release",
    query: "release:Abbey\\ Road",
    endpoint: "release"
  }
}
```

## Common Use Cases
- **Physical Release Lookup**: Find specific CD, vinyl, or digital releases
- **Barcode Scanning**: Look up releases by UPC/EAN barcode
- **Catalog Number Search**: Find releases by label catalog numbers
- **Format Filtering**: Distinguish between CD, vinyl, digital, etc.
- **Geographic Filtering**: Find releases by country
- **Status Filtering**: Distinguish between official, promo, bootleg releases
- **Label Discovery**: Find releases by record label
- **Date Range Filtering**: Find releases within specific time periods

## Error Handling
- **Invalid MBIDs**: Validates UUID format
- **Invalid Fields**: Checks against available search fields
- **Network Errors**: Graceful degradation with error responses
- **Query Errors**: Helpful error messages for invalid queries

## Dependencies
- Music::Musicbrainz::Search::BaseSearch for common functionality
- Music::Musicbrainz::BaseClient for HTTP requests
- Music::Musicbrainz::Exceptions for error handling 
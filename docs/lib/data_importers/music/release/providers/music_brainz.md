# DataImporters::Music::Release::Providers::MusicBrainz

## Summary
MusicBrainz data provider for Music::Release imports. This provider fetches release data from MusicBrainz API and populates Music::Release records with comprehensive information including format, country, status, labels, and metadata.

## Public Methods

### `#populate(item, query:)`
Populates Music::Release records with data from MusicBrainz.
- **Parameters**: 
  - `item` (ignored for multi-item imports)
  - `query` (ImportQuery) - The import query containing the album
- **Returns**: ImportResult with success/failure status and provider feedback

## Private Methods

### `#get_release_group_mbid(album)`
Extracts the MusicBrainz release group MBID from the album's identifiers.
- **Parameters**: `album` (Music::Album) - The album to get MBID for
- **Returns**: String - The release group MBID, or nil if not found

### `#find_existing_release(release_mbid, album)`
Finds an existing release by its MusicBrainz release ID.
- **Parameters**: 
  - `release_mbid` (String) - The MusicBrainz release ID
  - `album` (Music::Album) - The album to search within
- **Returns**: Music::Release or nil - The existing release if found

### `#create_release_from_data(release_data, album)`
Creates a new Music::Release instance from MusicBrainz data.
- **Parameters**: 
  - `release_data` (Hash) - Raw MusicBrainz release data
  - `album` (Music::Album) - The album to associate with
- **Returns**: Music::Release - New release instance (not saved)

### `#create_identifiers(release, release_data)`
Creates identifier records for the release.
- **Parameters**: 
  - `release` (Music::Release) - The release to create identifiers for
  - `release_data` (Hash) - Raw MusicBrainz release data
- **Returns**: void

### `#parse_release_date(date_string)`
Parses release date from MusicBrainz date string.
- **Parameters**: `date_string` (String) - MusicBrainz date format
- **Returns**: Date or nil - Parsed date or nil if invalid

### `#parse_status(status_string)`
Parses release status from MusicBrainz status string.
- **Parameters**: `status_string` (String) - MusicBrainz status
- **Returns**: Symbol - Status enum value (:official, :promotion, etc.)

### `#parse_format(release_data)`
Parses release format from MusicBrainz media data.
- **Parameters**: `release_data` (Hash) - Raw MusicBrainz release data
- **Returns**: Symbol - Format enum value (:cd, :vinyl, :digital, etc.)

### `#parse_labels(label_info)`
Parses and deduplicates label names from MusicBrainz data.
- **Parameters**: `label_info` (Array) - MusicBrainz label information
- **Returns**: Array of Strings - Unique label names

### `#build_metadata(release_data)`
Builds metadata hash from MusicBrainz release data.
- **Parameters**: `release_data` (Hash) - Raw MusicBrainz release data
- **Returns**: Hash - Metadata for JSONB storage

## Dependencies
- Music::Musicbrainz::Search::ReleaseSearch service
- Music::Release model
- Music::Album model
- Identifier model for external IDs

## Data Mapping

### MusicBrainz → Music::Release
- `title` → `release_name`
- `date` → `release_date` (parsed)
- `country` → `country`
- `status` → `status` (parsed to enum)
- `label-info` → `labels` (deduplicated array)
- `media[0].format` → `format` (parsed to enum)
- `id` → MusicBrainz release identifier
- `asin` → ASIN identifier (if present)

### Metadata Storage (JSONB)
- `asin` → `metadata["asin"]`
- `barcode` → `metadata["barcode"]`
- `packaging` → `metadata["packaging"]`
- `media` → `metadata["media"]`
- `text-representation` → `metadata["text_representation"]`
- `release-events` → `metadata["release_events"]`

## Format Parsing Strategy
Comprehensive mapping from MusicBrainz format strings to simplified enum values:

- **CD Formats**: "CD", "Compact Disc", "Enhanced CD", etc. → `:cd`
- **Vinyl Formats**: "Vinyl", "12\" Vinyl", "Gramophone record", etc. → `:vinyl`
- **Digital Formats**: "Digital Media", "Download Card", etc. → `:digital`
- **Cassette Formats**: "Cassette", "Microcassette" → `:cassette`
- **Other Formats**: All other formats → `:other`

## Usage Example
```ruby
album = Music::Album.find_by(title: "The Dark Side of the Moon")
query = DataImporters::Music::Release::ImportQuery.new(album: album)
provider = DataImporters::Music::Release::Providers::MusicBrainz.new

result = provider.populate(nil, query: query)
if result.success?
  puts "Successfully populated releases"
else
  puts "Failed: #{result.errors.join(', ')}"
end
```

## Design Decisions
- **Multi-Item Import**: Creates multiple releases from single query (all releases for album)
- **Comprehensive Format Parsing**: Maps extensive MusicBrainz format list to simplified enum
- **Label Deduplication**: Automatically removes duplicate label names
- **Flexible Metadata**: Stores additional data in JSONB for future extensibility
- **Error Resilience**: Continues processing even if individual releases fail

# DataImporters::Music::Artist::Finder

## Summary
Finds existing Music::Artist records before import using a multi-step search strategy. Prioritizes MusicBrainz ID matching for reliability, with fallback to exact name matching.

## Public Methods

### `#call(query:)`
Main method to find existing artists
- Parameters: query (ImportQuery) - Artist import query with name
- Returns: Music::Artist instance or nil if not found
- Purpose: Comprehensive search for existing artist records

## Search Strategy

### 1. MusicBrainz ID Lookup (Priority 1)
- Searches MusicBrainz API for artist name
- Extracts MusicBrainz ID (MBID) from first result
- Looks up existing artist by MBID in local database
- Most reliable method due to unique external identifiers

### 2. Exact Name Match (Fallback)
- Direct database query for exact name match
- Case-sensitive string comparison
- Used when MusicBrainz search fails or returns no MBID

### 3. Future: AI-Assisted Matching (Planned)
- Fuzzy matching for similar artist names
- Handle variations, typos, and alternate spellings
- Machine learning-based similarity scoring

## Private Methods

### `#search_musicbrainz(name)`
Searches MusicBrainz API for artist by name
- Returns: Hash with success status and artist data
- Handles network errors gracefully with logging
- Used for MBID discovery

### `#search_service`
- Returns: Music::Musicbrainz::Search::ArtistSearch instance
- Purpose: Memoized MusicBrainz API client

### `#find_by_musicbrainz_id(mbid)`
Finds artist by MusicBrainz identifier
- Uses base class `find_by_identifier` method
- Searches for `music_musicbrainz_artist_id` identifier type
- Most reliable duplicate detection method

### `#find_by_name(name)`
Finds artist by exact name match
- Direct ActiveRecord query on Music::Artist.name
- Case-sensitive matching
- Simple fallback when ID-based search fails

## Error Handling

### Network Failures
- MusicBrainz API failures are logged but don't prevent import
- Search continues with name-based fallback
- Graceful degradation ensures import can still proceed

### No Results Found
- Returns nil when no existing artist is found
- Allows importer to proceed with creating new artist
- Does not raise exceptions for missing records

## Search Prioritization
The search order ensures maximum reliability:
1. **External ID** - Most reliable, handles renamed artists
2. **Exact name** - Simple but effective for most cases
3. **Future AI** - Will handle edge cases and variations

## Dependencies
- Music::Musicbrainz::Search::ArtistSearch for external API access
- FinderBase for identifier-based search functionality
- Identifier model for storing external identifiers
- Music::Artist model for name-based queries
- Rails logger for error reporting

## Usage Example
```ruby
finder = DataImporters::Music::Artist::Finder.new
query = DataImporters::Music::Artist::ImportQuery.new(name: "Pink Floyd")

existing_artist = finder.call(query: query)
if existing_artist
  puts "Found existing artist: #{existing_artist.name}"
else
  puts "No existing artist found, will create new one"
end
```

## Logging
Network errors and API failures are logged with context:
```
MusicBrainz search failed in finder: Network timeout
```

This helps with debugging import issues while allowing the process to continue.
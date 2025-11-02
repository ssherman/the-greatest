# Services::Lists::Music::Songs::ItemsJsonEnricher

## Summary
Service object that enriches `items_json` on `Music::Songs::List` records with metadata from OpenSearch (local database) and MusicBrainz (external API). Searches local database first to prevent duplicate imports, then falls back to MusicBrainz for new songs.

Part of Phase 1 of the song list enrichment process. Phase 2 will import missing songs and create list_items from the enriched data.

## Purpose
After AI parsing extracts basic song information (rank, title, artists, release year) from HTML, this service:
1. **Searches OpenSearch first** for existing songs in local database (prevents duplicates)
2. If no local match found, searches MusicBrainz for recording metadata
3. Enriches items_json with song IDs and metadata from either source
4. Handles multi-artist songs gracefully
5. Skips entries without matches while continuing to process others
6. Tracks statistics for OpenSearch vs MusicBrainz matches

## Public Methods

### `.call(list:)`
Class method that instantiates and calls the enricher service.

**Parameters:**
- `list` (Music::Songs::List) - The song list to enrich

**Returns:**
- Hash with keys:
  - `:success` (Boolean) - Whether enrichment succeeded
  - `:message` (String) - Human-readable result message (includes source breakdown)
  - `:enriched_count` (Integer) - Number of songs successfully enriched
  - `:skipped_count` (Integer) - Number of songs skipped
  - `:total_count` (Integer) - Total number of songs processed
  - `:opensearch_matches` (Integer) - Number matched from local database
  - `:musicbrainz_matches` (Integer) - Number matched from MusicBrainz API

**Raises:**
- `ArgumentError` - If list is wrong type, items_json is missing, or songs array is missing

**Example:**
```ruby
list = Music::Songs::List.find(123)
result = Services::Lists::Music::Songs::ItemsJsonEnricher.call(list: list)

if result[:success]
  puts result[:message]
  # => "Enriched 48 of 50 songs (30 from OpenSearch, 18 from MusicBrainz, 2 skipped)"

  puts "OpenSearch matches: #{result[:opensearch_matches]}"  # 30
  puts "MusicBrainz matches: #{result[:musicbrainz_matches]}" # 18
end
```

### `#call`
Instance method that performs the enrichment operation.

**Returns:**
- Same hash structure as `.call` class method

**Processing Logic:**
1. Validates list type and items_json structure
2. Iterates through each song in items_json["songs"]
3. For each song:
   - **First tries OpenSearch** using `Search::Music::Search::SongByTitleAndArtists`
   - If OpenSearch match found (score ≥ 5.0):
     - Adds song_id, song_name, opensearch_match, opensearch_score
     - **Skips MusicBrainz** (no external API call)
     - Increments opensearch_matches counter
   - If no OpenSearch match:
     - Falls back to MusicBrainz using RecordingSearch
     - Extracts recording ID, name, and artist credits
     - Checks if song exists in database via MBID
     - Adds MusicBrainz metadata to entry
     - Increments musicbrainz_matches counter
4. Updates list.items_json atomically
5. Returns result with statistics from both sources

**Error Handling:**
- Individual song failures are caught and logged as warnings
- Failed songs are skipped, but processing continues
- Overall operation succeeds even if some songs fail
- Validation errors (ArgumentError) are re-raised

## Enrichment Data Added

Each song entry in items_json receives additional fields depending on the match source:

**OpenSearch Match (local database):**
- `song_id` (Integer) - Database primary key for Music::Song
- `song_name` (String) - Database song title
- `opensearch_match` (Boolean) - Always true when matched via OpenSearch
- `opensearch_score` (Float) - Relevance score from OpenSearch

**MusicBrainz Match (external API):**
- `mb_recording_id` (String) - MusicBrainz recording MBID
- `mb_recording_name` (String) - MusicBrainz recording title
- `mb_artist_ids` (Array<String>) - MusicBrainz artist MBIDs
- `mb_artist_names` (Array<String>) - MusicBrainz artist names
- `musicbrainz_match` (Boolean) - Always true when matched via MusicBrainz
- `song_id` (Integer) - Database primary key (if found via MBID lookup)
- `song_name` (String) - Database song title (if found via MBID lookup)

## Validations

### `#validate_list!`
Private method that performs validation checks:

1. **List Type:** Must be `Music::Songs::List`
   - Raises: `ArgumentError: "List must be a Music::Songs::List"`

2. **items_json Presence:** Must be present (not nil)
   - Raises: `ArgumentError: "List must have items_json populated"`

3. **songs Array:** items_json must contain "songs" array
   - Raises: `ArgumentError: "List items_json must contain songs array"`

## Dependencies

### Search Services
- `Search::Music::Search::SongByTitleAndArtists` - Local song search via OpenSearch
  - Uses `call(title:, artists:, **options)` method
  - Returns array of hashes with `:id`, `:score`, `:source` keys

### External Services
- `Music::Musicbrainz::Search::RecordingSearch` - Searches MusicBrainz for recordings
  - Uses `search_by_artist_and_title(artist_name, title)` method
  - Returns hash with `:success` and `:data` keys

### Database Models
- `Music::Songs::List` - The list being enriched
- `Music::Song` - For checking if songs already exist
  - Uses `with_identifier(:music_musicbrainz_recording_id, mbid)` scope
  - Uses `find_by(id:)` for OpenSearch results

### Rails Framework
- `Rails.logger` - For info, warning, and error logging

## OpenSearch Integration (Primary)

### Search Strategy
- Searches local database **before** MusicBrainz
- Uses structured parameters (title and artists array)
- Requires high relevance score (min_score: 5.0)
- Takes first result (highest scoring match)
- Returns nil on error (graceful fallback to MusicBrainz)

### Implementation
```ruby
def find_local_song(title, artists)
  return nil if title.blank? || artists.blank?

  search_results = ::Search::Music::Search::SongByTitleAndArtists.call(
    title: title,
    artists: artists,
    size: 1,
    min_score: 5.0
  )

  return nil if search_results.empty?

  result = search_results.first
  song = ::Music::Song.find_by(id: result[:id].to_i)

  return nil unless song

  {song: song, score: result[:score]}
rescue => e
  Rails.logger.error "Error searching OpenSearch for local song: #{e.message}"
  nil
end
```

### Benefits
- **Prevents duplicates**: Finds songs we already have
- **Faster**: No external API call needed
- **Higher quality**: Our songs already validated and linked
- **Graceful degradation**: Falls back to MusicBrainz on error

## MusicBrainz Integration (Fallback)

### Search Strategy
- Only runs if OpenSearch finds no match
- Joins artist names with ", " for multi-artist songs
- Searches by artist and title
- Takes first result (assumes correct match for curated lists)
- Skips songs without matches

### Response Parsing
Extracts data from MusicBrainz recording response:
```ruby
recording = search_result[:data]["recordings"].first
mb_recording_id = recording["id"]
mb_recording_name = recording["title"]

artist_credits = recording["artist-credit"] || []
mb_artist_ids = artist_credits.map { |c| c.dig("artist", "id") }.compact
mb_artist_names = artist_credits.map { |c| c.dig("artist", "name") }.compact
```

### Database Lookup
Checks for existing songs using identifier:
```ruby
Music::Song.with_identifier(:music_musicbrainz_recording_id, mb_recording_id).first
```

## Error Handling

### Individual Song Errors
- Caught in `enrich_song_entry` method
- Returns `{success: false, error: error_message}`
- Song is skipped, processing continues
- Warning logged with song details

### Search Failures
- No MusicBrainz match found
- Empty recordings array
- API errors or timeouts
- All result in skipped song with warning

### Unexpected Errors
- Logged as errors
- Returns failure result hash
- Does not raise (except ArgumentError for validation)

## Logging

Uses Rails logger with appropriate levels:

**Info Level:**
- Not explicitly used (could add progress logging)

**Warn Level:**
```ruby
Rails.logger.warn "Skipped enrichment for #{title} by #{artists}: #{error}"
```

**Error Level:**
```ruby
Rails.logger.error "ItemsJsonEnricher failed: #{e.message}"
```

## Performance Considerations

### Sequential Processing
- Each song processed one at a time
- One MusicBrainz API call per song
- For 100 songs, expect several minutes processing time

### Rate Limiting
- MusicBrainz limits to 1 request/second
- Natural processing time usually respects this
- No explicit throttling implemented

### Database Queries
- One identifier lookup per song (efficient scope)
- Final update is single atomic operation

### Memory Usage
- Entire items_json array loaded into memory
- Rebuilt with enriched data
- Suitable for lists up to ~1000 songs

## Usage Patterns

### From Console
```ruby
# Find list and enrich directly
list = Music::Songs::List.find(123)
result = Services::Lists::Music::Songs::ItemsJsonEnricher.call(list: list)

# Check results
puts "Enriched: #{result[:enriched_count]}"
puts "Skipped: #{result[:skipped_count]}"
```

### From Background Job
```ruby
# Queue job (preferred method)
Music::Songs::EnrichListItemsJsonJob.perform_async(list.id)
```

### From Avo Action
```ruby
# Select lists in Avo admin
# Click "Enrich items_json with MusicBrainz data"
# Jobs queued automatically
```

## Related Classes
- `Services::Lists::Music::Albums::ItemsJsonEnricher` - Album version of this service
- `Music::Songs::EnrichListItemsJsonJob` - Background job wrapper
- `Avo::Actions::Lists::Music::Songs::EnrichItemsJson` - Admin UI action
- `Music::Musicbrainz::Search::RecordingSearch` - MusicBrainz search service

## Testing
Comprehensive test coverage in `test/lib/services/lists/music/songs/items_json_enricher_test.rb`:
- 14 tests covering all scenarios
- 87 assertions
- Mocks both OpenSearch and MusicBrainz calls
- Tests validation, enrichment, error handling, and edge cases

**OpenSearch Flow Tests:**
- OpenSearch match found (skips MusicBrainz)
- Falls back to MusicBrainz when no OpenSearch match
- Handles OpenSearch errors gracefully
- Tracks mixed OpenSearch and MusicBrainz matches

**MusicBrainz Flow Tests:**
- Multi-artist song handling
- Missing artist-credit handling
- Empty recordings array
- Search failures and skipping

## Future Enhancements
- Phase 2: Create list_items from enriched data
- Batch processing for very large lists
- Match confidence scoring
- Progress tracking
- Manual override UI for incorrect matches

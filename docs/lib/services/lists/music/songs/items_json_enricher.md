# Services::Lists::Music::Songs::ItemsJsonEnricher

## Summary
Service object that enriches `items_json` on `Music::Songs::List` records with MusicBrainz recording metadata and database song IDs. Prepares AI-parsed song data for eventual list_item creation by adding all necessary identifiers and references.

Part of Phase 1 of the song list enrichment process. Phase 2 will import missing songs and create list_items from the enriched data.

## Purpose
After AI parsing extracts basic song information (rank, title, artists, release year) from HTML, this service:
1. Searches MusicBrainz for each song by artist and title
2. Enriches items_json with MusicBrainz recording metadata
3. Checks if songs exist in database and adds song_id/song_name
4. Handles multi-artist songs gracefully
5. Skips entries without matches while continuing to process others

## Public Methods

### `.call(list:)`
Class method that instantiates and calls the enricher service.

**Parameters:**
- `list` (Music::Songs::List) - The song list to enrich

**Returns:**
- Hash with keys:
  - `:success` (Boolean) - Whether enrichment succeeded
  - `:message` (String) - Human-readable result message
  - `:enriched_count` (Integer) - Number of songs successfully enriched
  - `:skipped_count` (Integer) - Number of songs skipped
  - `:total_count` (Integer) - Total number of songs processed

**Raises:**
- `ArgumentError` - If list is wrong type, items_json is missing, or songs array is missing

**Example:**
```ruby
list = Music::Songs::List.find(123)
result = Services::Lists::Music::Songs::ItemsJsonEnricher.call(list: list)

if result[:success]
  puts result[:message]
  # => "Enriched 48 of 50 songs (2 skipped)"
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
   - Joins artist names with ", " for search
   - Searches MusicBrainz using RecordingSearch
   - Extracts recording ID, name, and artist credits
   - Checks if song exists in database
   - Merges enrichment data into song entry
4. Updates list.items_json atomically
5. Returns result with statistics

**Error Handling:**
- Individual song failures are caught and logged as warnings
- Failed songs are skipped, but processing continues
- Overall operation succeeds even if some songs fail
- Validation errors (ArgumentError) are re-raised

## Enrichment Data Added

Each song entry in items_json receives these additional fields:

**Always Added (if MusicBrainz match found):**
- `mb_recording_id` (String) - MusicBrainz recording MBID
- `mb_recording_name` (String) - MusicBrainz recording title
- `mb_artist_ids` (Array<String>) - MusicBrainz artist MBIDs
- `mb_artist_names` (Array<String>) - MusicBrainz artist names

**Conditionally Added (if song exists in database):**
- `song_id` (Integer) - Database primary key for Music::Song
- `song_name` (String) - Database song title

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

### External Services
- `Music::Musicbrainz::Search::RecordingSearch` - Searches MusicBrainz for recordings
  - Uses `search_by_artist_and_title(artist_name, title)` method
  - Returns hash with `:success` and `:data` keys

### Database Models
- `Music::Songs::List` - The list being enriched
- `Music::Song` - For checking if songs already exist
  - Uses `with_identifier(:music_musicbrainz_recording_id, mbid)` scope

### Rails Framework
- `Rails.logger` - For info, warning, and error logging

## MusicBrainz Integration

### Search Strategy
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
- 10 tests covering all scenarios
- 52 assertions
- Mocks MusicBrainz API calls
- Tests validation, enrichment, error handling, and edge cases

## Future Enhancements
- Phase 2: Create list_items from enriched data
- Batch processing for very large lists
- Match confidence scoring
- Progress tracking
- Manual override UI for incorrect matches

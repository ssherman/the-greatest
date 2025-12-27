# [064] - Enrich Song List items_json with MusicBrainz Data

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-10-28
- **Started**: 2025-10-29
- **Completed**: 2025-10-29
- **Developer**: Claude

## Overview
Enrich the `items_json` field on `Music::Songs::List` records with MusicBrainz metadata and database song IDs. This prepares AI-parsed song data for eventual list_item creation by adding all necessary identifiers and references.

## Context
After AI parsing (via `list.parse_with_ai!`), the `items_json` field contains basic song information extracted from HTML: rank, title, artist names, and possibly release year. However, this data lacks the identifiers needed to find or import songs from MusicBrainz and create list_items.

This ticket enriches `items_json` entries with:
- MusicBrainz recording ID and name (for importing new songs)
- MusicBrainz artist IDs and names (for artist attribution)
- Database song ID and name (if song already exists)

This follows the same two-phase approach used for albums (task 052):
1. **Phase 1 (this ticket)**: Enrich items_json with all necessary metadata
2. **Phase 2 (future ticket)**: Create list_items from enriched items_json

## Current items_json Structure

```json
{
  "songs": [
    {
      "rank": 1,
      "title": "Come Together",
      "artists": ["The Beatles"],
      "release_year": 1969
    },
    {
      "rank": 2,
      "title": "Bohemian Rhapsody",
      "artists": ["Queen"],
      "release_year": 1975
    }
  ]
}
```

## Target items_json Structure

```json
{
  "songs": [
    {
      "rank": 1,
      "title": "Come Together",
      "artists": ["The Beatles"],
      "release_year": 1969,
      "mb_recording_id": "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
      "mb_recording_name": "Come Together",
      "mb_artist_ids": ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
      "mb_artist_names": ["The Beatles"],
      "song_id": 123,
      "song_name": "Come Together"
    },
    {
      "rank": 2,
      "title": "Bohemian Rhapsody",
      "artists": ["Queen"],
      "release_year": 1975,
      "mb_recording_id": "b1a9c0e1-0bb8-4fad-8ddb-78a22d1e6c4e",
      "mb_recording_name": "Bohemian Rhapsody",
      "mb_artist_ids": ["0383dadf-2a4e-4d10-a46a-e9e041da8eb3"],
      "mb_artist_names": ["Queen"],
      "song_id": 456,
      "song_name": "Bohemian Rhapsody"
    }
  ]
}
```

## Requirements
- [x] Create service object to enrich items_json with MusicBrainz data
- [x] Search MusicBrainz for each song entry by artist and title
- [x] Add MusicBrainz recording ID and name to items_json
- [x] Add MusicBrainz artist IDs and names to items_json
- [x] Check if song exists in database and add song_id/song_name if found
- [x] Handle multi-artist songs by joining artist names for search
- [x] Skip entries without MusicBrainz matches (log warnings)
- [x] Create Sidekiq job to run enrichment in background
- [x] Create AVO action to trigger enrichment from admin UI
- [x] Write comprehensive tests for service and job

## Technical Approach

### Service Object: `Services::Lists::Music::Songs::ItemsJsonEnricher`

**Location**: `app/lib/services/lists/music/songs/items_json_enricher.rb`

**Responsibilities**:
1. Validate list has items_json with songs array
2. Iterate through each song entry
3. Join artist names into single search string
4. Search MusicBrainz using `Music::Musicbrainz::Search::RecordingSearch.search_by_artist_and_title`
5. Take first result (assume correct match)
6. Extract MusicBrainz data from result
7. Check for existing song using `Music::Song.with_identifier(:music_musicbrainz_recording_id, mbid)`
8. Add all new fields to items_json entry
9. Update list.items_json with enriched data
10. Return result hash with success/failure and statistics

**Pattern to Follow**:
- Mirror `Services::Lists::Music::Albums::ItemsJsonEnricher` (app/lib/services/lists/music/albums/items_json_enricher.rb:6-123)
- Use `RecordingSearch#search_by_artist_and_title` instead of `ReleaseGroupSearch` (app/lib/music/musicbrainz/search/recording_search.rb:122-127)
- Return result hash: `{success:, data:, message:, enriched_count:, skipped_count:, total_count:}`

### Sidekiq Job: `Music::Songs::EnrichListItemsJsonJob`

**Location**: `app/sidekiq/music/songs/enrich_list_items_json_job.rb`

**Responsibilities**:
1. Accept list_id parameter
2. Load `Music::Songs::List` record
3. Call enricher service
4. Log results (success/failure, counts)
5. Handle errors with logging and re-raise

**Pattern to Follow**:
- Mirror `Music::Albums::EnrichListItemsJsonJob` (app/sidekiq/music/albums/enrich_list_items_json_job.rb:1-20)
- Include `Sidekiq::Job` module
- Use default queue (no queue_as needed)
- Rescue errors with logging and re-raise

### AVO Action: `Avo::Actions::Lists::Music::Songs::EnrichItemsJson`

**Location**: `app/avo/actions/lists/music/songs/enrich_items_json.rb`

**Responsibilities**:
1. Validate selected lists are `Music::Songs::List`
2. Validate lists have items_json populated
3. Queue enrichment job for each valid list
4. Return success message with count
5. Log warnings for skipped lists

**Pattern to Follow**:
- Mirror `Avo::Actions::Lists::Music::Albums::EnrichItemsJson` (app/avo/actions/lists/music/albums/enrich_items_json.rb:1-33)
- Extend `Avo::BaseAction`
- Validate records before queuing
- Use `perform_async(list.id)` to queue jobs

## Dependencies
- Existing: `Music::Musicbrainz::Search::RecordingSearch` (app/lib/music/musicbrainz/search/recording_search.rb:6-226)
- Existing: `Music::Song` model with `with_identifier` scope (app/models/music/song.rb:75-77)
- Existing: `Identifier` model and `IdentifierService` (app/lib/identifier_service.rb)
- Existing: `list.items_json` field populated by AI parsing
- Reference: `Services::Lists::Music::Albums::ItemsJsonEnricher` as pattern (app/lib/services/lists/music/albums/items_json_enricher.rb)

## Acceptance Criteria
- [x] Service enriches items_json with MusicBrainz recording ID and name
- [x] Service enriches items_json with MusicBrainz artist IDs and names
- [x] Service enriches items_json with song_id and song_name if song exists
- [x] Service handles multi-artist songs by joining names
- [x] Service skips entries without MusicBrainz matches and logs warnings
- [x] Service updates list.items_json atomically
- [x] Service returns result hash with success/failure and statistics
- [x] Sidekiq job queues and executes service successfully
- [x] AVO action appears in Music::Songs::List bulk actions
- [x] AVO action validates lists before queuing
- [x] All components have comprehensive test coverage
- [x] Logs provide clear visibility into enrichment process

## Design Decisions

### 1. First Match Strategy
**Decision**: Assume the first MusicBrainz search result is correct.
**Rationale**: For curated "best of" lists, titles and artists are usually accurate. Manual verification is available in Phase 2.
**Trade-off**: May occasionally match wrong recording, but simplifies implementation and reduces API calls.

### 2. Multi-Artist Join Strategy
**Decision**: Join artist names with ", " for MusicBrainz search.
**Rationale**: MusicBrainz search handles multiple artists in query string. Comma separator is conventional.
**Example**: `["Jay-Z", "Kanye West"]` → `"Jay-Z, Kanye West"`

### 3. Skip vs Error on No Match
**Decision**: Skip entries without matches, log warnings, continue processing.
**Rationale**: One bad entry shouldn't block entire list enrichment. Admin can review logs and fix manually.
**Alternative Considered**: Fail entire operation on first error (rejected - too strict).

### 4. Separate Service Namespace
**Decision**: Use `Services::Lists::Music::Songs::` namespace.
**Rationale**: Groups with other list-related services, follows domain-driven design, separates from data importers. Mirrors album enricher structure.
**Alternative Considered**: `DataImporters::Music::Lists::` (rejected - this isn't importing data from external source).

### 5. Recording vs Work
**Decision**: Enrich with MusicBrainz recording ID, not work ID.
**Rationale**: The Song model represents a specific recording (with duration, ISRC, etc), not an abstract work. This matches how `DataImporters::Music::Song::Importer` uses `RecordingSearch` (app/lib/data_importers/music/song/providers/musicbrainz/music_brainz.rb:10-46).
**MusicBrainz Distinction**:
- Recording = specific performance (e.g., "Bohemian Rhapsody - 1975 studio recording")
- Work = abstract composition (e.g., "Bohemian Rhapsody - the song as written")

### 6. Duration Handling
**Decision**: Do not extract or store duration from MusicBrainz search results in items_json.
**Rationale**: Duration will be populated when the song is actually imported (Phase 2). Adding it to items_json now provides no value for matching or verification.
**Note**: MusicBrainz recording data includes `length` in milliseconds, but we'll ignore it for enrichment.

## Key Differences from Album Implementation

### Search Service
- **Albums**: Use `Music::Musicbrainz::Search::ReleaseGroupSearch`
- **Songs**: Use `Music::Musicbrainz::Search::RecordingSearch`

### Field Names in items_json
- **Albums**: `mb_release_group_id`, `mb_release_group_name`, `album_id`, `album_name`
- **Songs**: `mb_recording_id`, `mb_recording_name`, `song_id`, `song_name`

### MusicBrainz Response Structure
- **Albums**: `search_result[:data]["release-groups"]` array
- **Songs**: `search_result[:data]["recordings"]` array

### Database Lookup
- **Albums**: `Music::Album.with_musicbrainz_release_group_id(mbid).first`
- **Songs**: `Music::Song.with_identifier(:music_musicbrainz_recording_id, mbid).first`

### List Type Validation
- **Albums**: Check `is_a?(Music::Albums::List)`
- **Songs**: Check `is_a?(Music::Songs::List)`

### items_json Key
- **Albums**: `items_json["albums"]`
- **Songs**: `items_json["songs"]`

## Implementation Checklist

### 1. Service Object
- [ ] Create `Services::Lists::Music::Songs::ItemsJsonEnricher`
- [ ] Implement `.call(list:)` class method
- [ ] Implement `#call` instance method with main loop
- [ ] Implement `#validate_list!` for type and data validation
- [ ] Implement `#enrich_song_entry(song_entry)` for individual enrichment
- [ ] Implement `#search_service` memoization for RecordingSearch
- [ ] Implement result helper methods (success_result, failure_result)
- [ ] Add error handling for individual entries (catch and skip)
- [ ] Add error handling for ArgumentError (re-raise validation errors)
- [ ] Add comprehensive logging (info, warn, error levels)

### 2. Sidekiq Job
- [ ] Generate job: `bin/rails generate sidekiq:job music/songs/enrich_list_items_json`
- [ ] Implement `perform(list_id)` method
- [ ] Load list and call service
- [ ] Log job start, success, and failure
- [ ] Rescue and re-raise errors with context

### 3. AVO Action
- [ ] Create `Avo::Actions::Lists::Music::Songs::EnrichItemsJson`
- [ ] Extend `Avo::BaseAction`
- [ ] Implement `handle` method
- [ ] Validate record types (Music::Songs::List only)
- [ ] Validate items_json presence
- [ ] Queue job for each valid list
- [ ] Return success/error messages

### 4. AVO Resource Integration
- [ ] Add action to `app/avo/resources/music_songs_list.rb`
- [ ] Add to `action` declaration for bulk actions

### 5. Testing - Service
- [ ] Test successful enrichment of all songs
- [ ] Test validation error: wrong list type
- [ ] Test validation error: nil items_json
- [ ] Test validation error: missing songs array
- [ ] Test multi-artist song handling (artist name joining)
- [ ] Test partial failure (some songs enriched, some skipped)
- [ ] Test no MusicBrainz match (skipped with warning)
- [ ] Test existing song in database (song_id/song_name added)
- [ ] Test song not in database (song_id/song_name not added)
- [ ] Test result hash structure (success, message, counts)
- [ ] Mock MusicBrainz API calls with Mocha

### 6. Testing - Job
- [ ] Test job execution calls service
- [ ] Test job with successful enrichment
- [ ] Test job with failed enrichment
- [ ] Test job enqueueing (Sidekiq::Testing.fake!)
- [ ] Test job error handling and logging
- [ ] Test job passes correct list_id to service

### 7. Fixtures
- [ ] Create or update `test/fixtures/lists.yml` with `music_songs_list_with_items_json` fixture
- [ ] Ensure fixture has `type: "Music::Songs::List"`
- [ ] Ensure fixture has populated items_json with songs array

## MusicBrainz API Details

### Search Method
```ruby
Music::Musicbrainz::Search::RecordingSearch#search_by_artist_and_title(artist_name, title, options = {})
```

### Request Format
- Builds Lucene query: `artist:The\\ Beatles AND title:Come\\ Together`
- Special characters and spaces are escaped
- Multi-artist names joined with comma before search

### Response Structure
```ruby
{
  success: true,
  data: {
    "count" => 1,
    "offset" => 0,
    "recordings" => [
      {
        "id" => "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",  # MusicBrainz recording ID
        "title" => "Come Together",
        "length" => 259000,  # Duration in milliseconds (ignore for enrichment)
        "artist-credit" => [
          {
            "artist" => {
              "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
              "name" => "The Beatles"
            }
          }
        ],
        "isrcs" => ["GBUM71505078"],  # Ignore for enrichment
        "score" => "100"  # Match confidence (ignore for enrichment)
      }
    ]
  },
  errors: [],
  metadata: {...}
}
```

### Extracting Data
```ruby
# Get recordings array
recordings = search_result[:data]["recordings"]

# First recording
recording = recordings.first

# Recording ID and title
mb_recording_id = recording["id"]
mb_recording_name = recording["title"]

# Artist credits (array for multi-artist songs)
artist_credits = recording["artist-credit"] || []
mb_artist_ids = artist_credits.map { |credit| credit.dig("artist", "id") }.compact
mb_artist_names = artist_credits.map { |credit| credit.dig("artist", "name") }.compact
```

## Example Service Usage

```ruby
# From admin UI action or console
list = Music::Songs::List.find(123)
result = Services::Lists::Music::Songs::ItemsJsonEnricher.call(list: list)

# Returns:
# {
#   success: true,
#   message: "Enriched 2 of 2 songs (0 skipped)",
#   enriched_count: 2,
#   skipped_count: 0,
#   total_count: 2
# }
```

## Example Background Job Usage

```ruby
# Queue from AVO action or console
Music::Songs::EnrichListItemsJsonJob.perform_async(list.id)
```

## Edge Cases to Handle

### Multi-Artist Songs
- **Input**: `{"artists": ["Jay-Z", "Kanye West"]}`
- **Search query**: `artist:Jay-Z,\\ Kanye\\ West AND title:...`
- **MusicBrainz response**: Multiple artists in artist-credit array
- **Output**: Arrays of IDs and names in items_json

### No MusicBrainz Match
- **Scenario**: Obscure song, typo in title, artist name mismatch
- **Behavior**: Log warning, increment skip counter, return original entry unchanged
- **Log example**: `"Skipped enrichment for Obscure Song by Unknown Artist: No MusicBrainz match found"`

### Song Already Exists
- **Scenario**: Song previously imported with MusicBrainz recording ID
- **Behavior**: Add song_id and song_name to enrichment data
- **Query**: `Music::Song.with_identifier(:music_musicbrainz_recording_id, mb_recording_id).first`

### Song Not in Database
- **Scenario**: Valid MusicBrainz match, but song not imported yet
- **Behavior**: Add only MusicBrainz fields, omit song_id/song_name
- **Rationale**: Phase 2 will import the song before creating list_items

### Empty items_json
- **Scenario**: List with `items_json: nil` or `items_json: {}`
- **Behavior**: Raise ArgumentError in validation
- **Message**: Clear error indicating items_json is required

### Wrong List Type
- **Scenario**: Accidentally called on `Music::Albums::List`
- **Behavior**: Raise ArgumentError in validation
- **Message**: "List must be a Music::Songs::List"

### MusicBrainz API Error
- **Scenario**: Network timeout, rate limit, server error
- **Behavior**: search_result[:success] is false, skip entry with logged error
- **Recovery**: Individual API errors don't fail entire enrichment

## Performance Considerations

### Sequential Processing
Each song is enriched sequentially with a MusicBrainz API call. For large lists (100+ songs), this could take several minutes.

### Rate Limiting
MusicBrainz has rate limits (1 request/second). The current implementation doesn't add explicit delays, relying on natural processing time. May need throttling for very large lists.

### Database Queries
Uses efficient scope (`with_identifier`) for existing song lookups, one query per song.

### Memory Efficiency
Entire items_json array is loaded into memory and rebuilt. For lists with thousands of songs, this could be optimized with batch processing.

## Future Improvements

### Phase 2 Implementation
Create service to automatically import missing songs and create list_items from enriched items_json (similar to task 055 for albums).

### Batch Processing
Process songs in batches with progress tracking for very large lists.

### Match Confidence Scoring
Add logic to evaluate match quality using MusicBrainz `score` field and flag uncertain matches for manual review.

### Retry Logic
Add retry mechanism for transient MusicBrainz API failures.

### Progress Tracking
Add real-time progress updates via ActionCable or similar for long-running enrichments.

### Manual Override
Allow admins to manually correct incorrect MusicBrainz matches before creating list_items (AI validation task similar to 054).

---

## Notes for Implementation

### File Structure
```
web-app/app/lib/services/lists/music/songs/
└── items_json_enricher.rb

web-app/app/sidekiq/music/songs/
└── enrich_list_items_json_job.rb

web-app/app/avo/actions/lists/music/songs/
└── enrich_items_json.rb

web-app/test/lib/services/lists/music/songs/
└── items_json_enricher_test.rb

web-app/test/sidekiq/music/songs/
└── enrich_list_items_json_job_test.rb
```

### Namespace Consistency
All files follow the `Music::Songs::` namespace pattern established in the codebase.

### Code Reuse
Service implementation should closely mirror the album enricher for consistency and maintainability.

### Test Coverage
Target 100% coverage for the service. Job tests should cover happy path, error handling, and queuing.

### Logging Strategy
Use Rails logger with contextual prefixes:
- `[SONG_LIST_ENRICHMENT]` for service logs
- Include list ID, song title/artists in log messages
- Use appropriate log levels (info for progress, warn for skips, error for failures)

---

## Related Tasks

- **Prerequisite**: [052 - Enrich Album List items_json with MusicBrainz Data](052-import-list-from-musicbrainz-non-series.md) - Pattern to follow
- **Future**: Phase 2 - Import songs and create list_items from enriched items_json (similar to task 055)
- **Future**: AI validation task to identify incorrect MusicBrainz matches (similar to task 054)

---

## Implementation Notes

### Approach Taken
Followed the exact pattern established by the album enricher (task 052) with appropriate adaptations for songs:
- Created service object using class method pattern (`self.call`)
- Implemented sequential processing with individual error handling for each song
- Used RecordingSearch service instead of ReleaseGroupSearch
- Added comprehensive validation and error handling
- Followed existing patterns for Sidekiq jobs and Avo actions

### Key Files Changed
**Service Layer:**
- `app/lib/services/lists/music/songs/items_json_enricher.rb` - Main enrichment service
  - Validates list type and items_json structure
  - Searches MusicBrainz for each song by artist and title
  - Enriches with mb_recording_id, mb_recording_name, mb_artist_ids, mb_artist_names
  - Adds song_id and song_name if song exists in database
  - Returns result hash with counts

**Background Jobs:**
- `app/sidekiq/music/songs/enrich_list_items_json_job.rb` - Sidekiq job for async processing
  - Accepts list_id parameter
  - Calls enricher service
  - Logs results with appropriate levels

**Admin UI:**
- `app/avo/actions/lists/music/songs/enrich_items_json.rb` - Avo bulk action
  - Validates selected lists
  - Queues jobs for valid lists
  - Returns success message with count
- `app/avo/resources/music_songs_list.rb` - Added action to resource

**Tests:**
- `test/lib/services/lists/music/songs/items_json_enricher_test.rb` - 10 comprehensive tests
- `test/sidekiq/music/songs/enrich_list_items_json_job_test.rb` - 6 job tests
- `test/fixtures/lists.yml` - Added music_songs_list_with_items_json fixture

### Challenges Encountered
None - implementation was straightforward following the established album enricher pattern.

### Deviations from Plan
No deviations. Implementation followed the plan exactly as specified in the task document.

### Code Examples

**Service Usage:**
```ruby
# From admin UI action or console
list = Music::Songs::List.find(123)
result = Services::Lists::Music::Songs::ItemsJsonEnricher.call(list: list)

# Returns:
# {
#   success: true,
#   message: "Enriched 2 of 2 songs (0 skipped)",
#   enriched_count: 2,
#   skipped_count: 0,
#   total_count: 2
# }
```

**Background Job Usage:**
```ruby
# Queue from AVO action or console
Music::Songs::EnrichListItemsJsonJob.perform_async(list.id)
```

**Enriched items_json Structure:**
```json
{
  "songs": [
    {
      "rank": 1,
      "title": "Come Together",
      "artists": ["The Beatles"],
      "release_year": 1969,
      "mb_recording_id": "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
      "mb_recording_name": "Come Together",
      "mb_artist_ids": ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
      "mb_artist_names": ["The Beatles"],
      "song_id": 123,
      "song_name": "Come Together"
    }
  ]
}
```

### Testing Approach
**Service Tests (10 tests, 52 assertions):**
- Successful enrichment with MusicBrainz data
- Enrichment with existing song in database
- Multi-artist song handling
- Skipping entries without matches
- Validation errors (wrong list type, missing items_json, missing songs array)
- Error handling (service errors, empty results, missing artist credits)

**Job Tests (6 tests, 10 assertions):**
- Successful job execution with logging
- Failure logging
- List not found error handling
- Unexpected error handling
- Job enqueueing
- Correct list loading

All tests use mocking for MusicBrainz API calls to avoid external dependencies.

### Performance Considerations
- Sequential processing: Each song requires one MusicBrainz API call
- Database lookups use efficient `with_identifier` scope
- For lists with 100+ songs, processing takes several minutes
- MusicBrainz rate limits (1 req/sec) are respected by natural processing time
- Background job allows async processing without blocking UI

### Future Improvements
**Phase 2 - List Item Creation:**
Create service to automatically import missing songs and create list_items from enriched items_json (similar to task 055 for albums).

**Additional Enhancements:**
- Batch processing with progress tracking for very large lists
- Match confidence scoring using MusicBrainz `score` field
- Retry logic for transient API failures
- Real-time progress updates via ActionCable
- Manual override UI for incorrect matches

### Lessons Learned
- Following established patterns makes implementation straightforward and consistent
- The album enricher pattern works equally well for songs with minimal adaptation
- Comprehensive test coverage (16 tests, 62 assertions) provides confidence
- Sequential processing with individual error handling is more robust than batch processing

### Related PRs
*To be added when PR is created*

### Documentation Updated
- [x] This task file updated with implementation notes
- [x] Code includes inline documentation and comments
- [x] Test files serve as usage documentation
- [x] Class documentation created for all new classes

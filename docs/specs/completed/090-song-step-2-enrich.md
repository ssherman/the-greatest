# [090] - Song Wizard: Step 2 - Enrich

## Status
- **Status**: Completed
- **Completed**: 2025-11-30
- **Priority**: High
- **Created**: 2025-01-19
- **Part**: 5 of 10

## Overview
Implement Step 2 of the song list wizard where unverified `list_items` (created in Step 1: Parse) are enriched with metadata from OpenSearch (local database) and MusicBrainz (external API). This step attempts to match each parsed song to an existing `Music::Song` record or gather MusicBrainz IDs for later import. Users see real-time progress updates via polling as the background job processes each item.

## Context

This is **Part 5 of 10** in the Song List Wizard implementation:

1. [086] Infrastructure - Complete
2. [087] Wizard UI Shell - Complete
3. [088] Step 0: Import Source Choice - Complete
4. [089] Step 1: Parse HTML - Complete
5. **[090] Step 2: Enrich** - You are here
6. [091] Step 3: Validation
7. [092] Step 4: Review UI
8. [093] Step 4: Actions
9. [094] Step 5: Import
10. [095] Polish & Integration

### The Flow

**Custom HTML Path**:
```
Step 0 (source) -> Step 1 (parse) -> Step 2 (enrich) -> Step 3 (validate) -> ...
```

### What This Builds

This task implements:
- Enrich step view component with stats display, progress tracking UI, and item preview
- Background job (`Music::Songs::WizardEnrichListItemsJob`) that:
  - Iterates through unverified `list_items`
  - Tries OpenSearch first (fast local lookup)
  - Falls back to MusicBrainz API if no local match
  - Updates `list_item.metadata` with enrichment results
  - Updates `list_item.listable_id` if a matching `Music::Song` is found
  - Updates wizard_state with job progress periodically
- Service object (`Services::Lists::Music::Songs::ListItemEnricher`) for single-item enrichment logic
- Controller logic to enqueue enrich job and handle step advancement

This task does NOT implement:
- Validation logic (covered in [091])
- User verification/approval UI (covered in [092])
- Import/creation of new songs (covered in [094])

### Key Design Decisions

**Job vs Service Pattern**:
- **Job**: `Music::Songs::WizardEnrichListItemsJob` - Sidekiq job for async execution, handles progress updates
- **Service**: `Services::Lists::Music::Songs::ListItemEnricher` - Enriches a single `ListItem`, called by job
- **Why**: Separate orchestration (job handles looping/progress) from business logic (service handles matching) for testability

**Enrichment Strategy**:
1. **OpenSearch First**: Local database search is fast (~10ms per item) and preferred
2. **MusicBrainz Fallback**: External API is slower (~200-500ms per item due to rate limits) but provides MBID for import
3. **No Match**: Item remains unenriched but is not an error

**Progress Tracking Approach**:
- Use `list.update_wizard_job_status(status:, progress:, metadata:)` helper (from [086])
- Progress updates: Every 10 items or 5 seconds, whichever comes first
- Metadata includes: `processed_items`, `total_items`, `opensearch_matches`, `musicbrainz_matches`, `not_found`
- Polling frequency: 2 seconds (defined in `wizard_step_controller.js`)

**Data Storage**:
- Update `list_items.metadata` JSONB with enrichment results
- Set `list_items.listable_id` when `Music::Song` found (local or via MBID lookup)
- Leave `verified: false` (verification happens in Step 3)

**Reusing Existing Logic**:
- Heavily adapts patterns from `Services::Lists::Music::Songs::ItemsJsonEnricher`
- Uses same OpenSearch query: `Search::Music::Search::SongByTitleAndArtists`
- Uses same MusicBrainz API: `Music::Musicbrainz::Search::RecordingSearch`

---

## Requirements

### Functional Requirements

#### FR-1: Enrich Step View Component
**Contract**: Display enrichment stats, job status, progress bar, item preview, and navigation controls

**UI States**:

**State 1 - Idle (Ready to Enrich)**:
- Shows count of items to enrich
- "Start Enrichment" button (enabled)
- Stats cards showing: Total items, Items needing enrichment

**State 2 - Running**:
- Progress bar with percentage
- Status text: "Enriching 45/100 items..."
- Animated indicator
- "Start Enrichment" button hidden or disabled

**State 3 - Completed**:
- Success message: "Enrichment Complete!"
- Stats cards showing:
  - Total items enriched
  - OpenSearch matches (count + percentage)
  - MusicBrainz matches (count + percentage)
  - Not found (count + percentage)
- Preview table of enriched items (first 10, scrollable)
- "Continue to Validation" button (enabled)
- "Re-enrich" button (to restart if needed)

**State 4 - Failed**:
- Error message with details
- "Retry Enrichment" button

**Stimulus Controller Integration**:
- Uses `wizard_step_controller.js` (already implemented)
- Targets: `progressBar`, `statusText`
- Conditionally attached only when job is "running"
- Auto-refreshes via Turbo Frame when job completes

**Implementation**: `app/components/admin/music/songs/wizard/enrich_step_component.html.erb`

#### FR-2: Background Job for Enrichment
**Contract**: Enrich all unverified list_items asynchronously with progress tracking

**Job Specification**:
- **File**: `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb`
- **Queue**: `default` (standard Sidekiq queue)
- **Parameters**: `list_id` (integer)

**Job Workflow**:
1. Find list by ID
2. Validate preconditions (has unverified items to enrich)
3. Update wizard_state: `{job_status: "running", job_progress: 0}`
4. Reset any previous enrichment metadata on items (for idempotency)
5. Iterate through unverified list_items:
   - Call `Services::Lists::Music::Songs::ListItemEnricher.call(list_item:)`
   - Track stats (opensearch_matches, musicbrainz_matches, not_found)
   - Update progress every 10 items: `{job_progress: N, job_metadata: {processed_items: X, total_items: Y, ...}}`
6. Update wizard_state: `{job_status: "completed", job_progress: 100, job_metadata: {final stats}}`
7. Handle errors and update wizard_state accordingly

**Progress Update Frequency**:
- Every 10 items processed
- Or every 5 seconds (whichever comes first)
- Always at start (0%) and end (100%)

**Error Handling**:
- Individual item failures: Log warning, continue to next item, increment `failed_count`
- Database errors: Log error, update wizard_state with error message, raise for retry
- Missing items: Fail with clear error message

**Implementation Pattern**: Reference `wizard_parse_list_job.rb` (lines 1-70)

#### FR-3: Single Item Enrichment Service
**Contract**: Enrich a single ListItem with OpenSearch and MusicBrainz data

**Service Specification**:
- **File**: `app/lib/services/lists/music/songs/list_item_enricher.rb`
- **Interface**: `Services::Lists::Music::Songs::ListItemEnricher.call(list_item:)`

**Input**:
- `list_item`: A `ListItem` record with `metadata` containing `title` and `artists`

**Output** (Result hash):
```ruby
{
  success: true,
  source: :opensearch,  # or :musicbrainz or :not_found
  song_id: 123,         # or nil
  data: {               # Enrichment data added to metadata
    "song_id" => 123,
    "song_name" => "Come Together",
    "opensearch_match" => true,
    "opensearch_score" => 15.5
  }
}
```

**Enrichment Logic**:

1. **Extract metadata**:
   ```ruby
   title = list_item.metadata["title"]
   artists = list_item.metadata["artists"]
   ```

2. **Try OpenSearch (local database)**:
   - Call `Search::Music::Search::SongByTitleAndArtists.call(title:, artists:, size: 1, min_score: 5.0)`
   - If match found with score >= 5.0:
     - Look up `Music::Song` by ID
     - Set `list_item.listable_id = song.id`
     - Update metadata with OpenSearch enrichment data
     - Return success with `source: :opensearch`

3. **Try MusicBrainz (external API)**:
   - Call `RecordingSearch.new.search_by_artist_and_title(artist_name, title)`
   - If match found:
     - Extract MBID and artist credits
     - Check if `Music::Song` exists with this MBID via `with_identifier`
     - If song exists: set `list_item.listable_id = song.id`
     - Update metadata with MusicBrainz enrichment data
     - Return success with `source: :musicbrainz`

4. **No match found**:
   - Return `{success: false, source: :not_found, data: {}}`

**Metadata Update Schema**:

**OpenSearch Match**:
```ruby
{
  "song_id" => 123,
  "song_name" => "Come Together",
  "opensearch_match" => true,
  "opensearch_score" => 15.5
}
```

**MusicBrainz Match (song exists)**:
```ruby
{
  "song_id" => 456,
  "song_name" => "Come Together",
  "mb_recording_id" => "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
  "mb_recording_name" => "Come Together",
  "mb_artist_ids" => ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
  "mb_artist_names" => ["The Beatles"],
  "musicbrainz_match" => true
}
```

**MusicBrainz Match (song does not exist)**:
```ruby
{
  "mb_recording_id" => "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
  "mb_recording_name" => "Come Together",
  "mb_artist_ids" => ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
  "mb_artist_names" => ["The Beatles"],
  "musicbrainz_match" => true
}
```

**Reference Implementation**: `app/lib/services/lists/music/songs/items_json_enricher.rb` (lines 64-120)

#### FR-4: Controller Integration
**Contract**: Enqueue enrichment job and handle step advancement

**Method Updates**:

1. **`load_enrich_step_data`** (line 89-90):
   ```ruby
   def load_enrich_step_data
     @unverified_items = @list.list_items.unverified.ordered
     @total_items = @unverified_items.count
     @enriched_items = @unverified_items.where.not(listable_id: nil)
     @enriched_count = @enriched_items.count
   end
   ```

2. **`enqueue_enrich_job`** (line 109-110):
   ```ruby
   def enqueue_enrich_job
     Music::Songs::WizardEnrichListItemsJob.perform_async(wizard_entity.id)
   end
   ```

3. **`advance_step` override** (add "enrich" case):
   - Similar pattern to `advance_from_parse_step`
   - If idle/failed: Set status to "running", enqueue job, redirect to enrich step
   - If completed: Advance to validate step
   - If running: Show "in progress" alert

**Implementation Location**: `app/controllers/admin/music/songs/list_wizard_controller.rb`

---

### Non-Functional Requirements

#### NFR-1: Performance
- [ ] Enrichment completes in < 2 minutes for lists with < 100 items
- [ ] Enrichment completes in < 10 minutes for lists with 100-500 items
- [ ] OpenSearch queries: < 50ms per item (p95)
- [ ] MusicBrainz queries: < 1 second per item (with rate limiting)
- [ ] Progress updates add < 100ms overhead per batch
- [ ] Polling adds < 10ms overhead per request

#### NFR-2: Data Integrity
- [ ] Job is idempotent (can be safely retried)
- [ ] Previous enrichment data cleared before re-enrichment
- [ ] Individual item failures don't affect other items
- [ ] wizard_state updates are atomic
- [ ] Failed jobs do not corrupt existing data

#### NFR-3: Error Handling
- [ ] OpenSearch timeout handled gracefully (skip to MusicBrainz)
- [ ] MusicBrainz rate limit handled (wait and retry, or skip)
- [ ] Network errors logged and counted as "not found"
- [ ] Empty metadata (missing title/artists) handled gracefully
- [ ] Database constraint violations logged and handled

#### NFR-4: Observability
- [ ] Job start/completion logged with metadata
- [ ] Each item enrichment logged (debug level)
- [ ] OpenSearch/MusicBrainz calls logged with duration
- [ ] Errors include full context for debugging
- [ ] Final stats logged at info level

---

## Contracts & Schemas

### ListItem Metadata Schema (After Enrichment)

**JSON Schema** (stored in `list_items.metadata` JSONB column):

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["title", "artists"],
  "properties": {
    "rank": {
      "type": ["integer", "null"],
      "description": "Original rank from parsed HTML"
    },
    "title": {
      "type": "string",
      "description": "Song title",
      "minLength": 1
    },
    "artists": {
      "type": "array",
      "items": {"type": "string"},
      "minItems": 1,
      "description": "Array of artist names"
    },
    "album": {
      "type": ["string", "null"],
      "description": "Album name if present"
    },
    "release_year": {
      "type": ["integer", "null"],
      "description": "Release year if present"
    },
    "song_id": {
      "type": ["integer", "null"],
      "description": "ID of matched Music::Song record"
    },
    "song_name": {
      "type": ["string", "null"],
      "description": "Title of matched song (for display)"
    },
    "opensearch_match": {
      "type": "boolean",
      "description": "True if matched via OpenSearch"
    },
    "opensearch_score": {
      "type": ["number", "null"],
      "description": "OpenSearch match score"
    },
    "mb_recording_id": {
      "type": ["string", "null"],
      "description": "MusicBrainz recording MBID"
    },
    "mb_recording_name": {
      "type": ["string", "null"],
      "description": "Recording title from MusicBrainz"
    },
    "mb_artist_ids": {
      "type": ["array", "null"],
      "items": {"type": "string"},
      "description": "MusicBrainz artist MBIDs"
    },
    "mb_artist_names": {
      "type": ["array", "null"],
      "items": {"type": "string"},
      "description": "Artist names from MusicBrainz"
    },
    "musicbrainz_match": {
      "type": "boolean",
      "description": "True if matched via MusicBrainz"
    }
  }
}
```

### Endpoint Table

| Verb | Path | Purpose | Params/Body | Auth | Response |
|------|------|---------|-------------|------|----------|
| GET | `/wizard/step/enrich` | Show enrich step | - | admin | HTML (Turbo Frame) |
| POST | `/wizard/step/enrich/advance` | Start enrichment job or advance | step="enrich" | admin | 302 redirect |
| GET | `/wizard/step/enrich/status` | Get job status | - | admin | JSON (status endpoint schema) |

### Status Endpoint Response

**Endpoint**: `GET /admin/songs/lists/:list_id/wizard/step/enrich/status`

**Response** (running):
```json
{
  "status": "running",
  "progress": 45,
  "error": null,
  "metadata": {
    "processed_items": 45,
    "total_items": 100,
    "opensearch_matches": 30,
    "musicbrainz_matches": 10,
    "not_found": 5
  }
}
```

**Response** (completed):
```json
{
  "status": "completed",
  "progress": 100,
  "error": null,
  "metadata": {
    "processed_items": 100,
    "total_items": 100,
    "opensearch_matches": 60,
    "musicbrainz_matches": 25,
    "not_found": 15,
    "enriched_at": "2025-01-23T15:30:00Z"
  }
}
```

**Response** (failed):
```json
{
  "status": "failed",
  "progress": 45,
  "error": "MusicBrainz API rate limit exceeded",
  "metadata": {
    "processed_items": 45,
    "total_items": 100
  }
}
```

### Wizard State Update

**Before** (after parse step):
```json
{
  "current_step": 2,
  "import_source": "custom_html",
  "job_status": "idle",
  "job_progress": 0,
  "job_error": null,
  "job_metadata": {}
}
```

**During enrichment**:
```json
{
  "current_step": 2,
  "import_source": "custom_html",
  "job_status": "running",
  "job_progress": 45,
  "job_error": null,
  "job_metadata": {
    "processed_items": 45,
    "total_items": 100,
    "opensearch_matches": 30,
    "musicbrainz_matches": 10,
    "not_found": 5
  }
}
```

**After successful enrichment**:
```json
{
  "current_step": 2,
  "import_source": "custom_html",
  "job_status": "completed",
  "job_progress": 100,
  "job_error": null,
  "job_metadata": {
    "processed_items": 100,
    "total_items": 100,
    "opensearch_matches": 60,
    "musicbrainz_matches": 25,
    "not_found": 15,
    "enriched_at": "2025-01-23T15:30:00Z"
  }
}
```

---

## Acceptance Criteria

### View Component
- [ ] `Admin::Music::Songs::Wizard::EnrichStepComponent` renders all UI states
- [ ] Stats cards show: Total, OpenSearch matches, MusicBrainz matches, Not found
- [ ] "Start Enrichment" button exists when job idle/failed
- [ ] Progress bar exists with `data-wizard-step-target="progressBar"` attribute
- [ ] Status text shows "Enriching X/Y items..." with `data-wizard-step-target="statusText"`
- [ ] Error display area shown when job failed
- [ ] Preview table shows enriched items (scrollable, max 10 visible)
- [ ] Uses Stimulus controller conditionally (only when running)
- [ ] Turbo Frame auto-refreshes on job completion

### Background Job
- [ ] `Music::Songs::WizardEnrichListItemsJob` exists in correct namespace
- [ ] Job updates wizard_state to "running" at start
- [ ] Job iterates through all unverified items
- [ ] Job calls `ListItemEnricher.call` for each item
- [ ] Job updates progress every 10 items
- [ ] Job updates wizard_state to "completed" on success with final stats
- [ ] Job updates wizard_state to "failed" on error
- [ ] Job logs all important events (start, progress, success, failure)
- [ ] Job is idempotent (clears previous enrichment data on retry)

### Service Object
- [ ] `Services::Lists::Music::Songs::ListItemEnricher` exists
- [ ] Service tries OpenSearch first with min_score 5.0
- [ ] Service falls back to MusicBrainz if no OpenSearch match
- [ ] Service updates `list_item.metadata` with enrichment data
- [ ] Service sets `list_item.listable_id` when song found
- [ ] Service returns result hash with `success`, `source`, `data`
- [ ] Service handles missing title/artists gracefully
- [ ] Service handles API errors gracefully

### Controller Logic
- [ ] `load_enrich_step_data` loads item counts and stats
- [ ] `enqueue_enrich_job` calls the Sidekiq job
- [ ] Advancing from enrich step validates job status
- [ ] Cannot advance if job not completed
- [ ] Can advance to validate step when job completed
- [ ] Flash alert shown if trying to advance prematurely

### Progress Tracking
- [ ] Polling starts automatically when step loads with running job
- [ ] Progress bar updates every poll cycle
- [ ] Status text shows "Enriching X/Y items..."
- [ ] Status text shows "Complete! X matched, Y not found" when done
- [ ] Error message displayed if job fails
- [ ] Next button enabled when job completes

### Error Handling
- [ ] Empty list (no unverified items) handled gracefully
- [ ] OpenSearch timeout doesn't stop enrichment (falls back to MB)
- [ ] MusicBrainz errors logged and item counted as "not found"
- [ ] Individual item failures don't stop job
- [ ] Final stats include failed items count

---

## Golden Examples

### Example 1: Successful Enrichment Flow (OpenSearch Match)

**Input** (ListItem from parse step):
```ruby
ListItem.new(
  list_id: 123,
  listable_type: "Music::Song",
  listable_id: nil,
  verified: false,
  position: 1,
  metadata: {
    "rank" => 1,
    "title" => "Come Together",
    "artists" => ["The Beatles"],
    "album" => "Abbey Road",
    "release_year" => 1969
  }
)
```

**OpenSearch Response**:
```ruby
[{id: "456", score: 18.5, source: {"title" => "Come Together"}}]
```

**Output** (ListItem after enrichment):
```ruby
{
  list_id: 123,
  listable_type: "Music::Song",
  listable_id: 456,  # Now linked!
  verified: false,
  position: 1,
  metadata: {
    "rank" => 1,
    "title" => "Come Together",
    "artists" => ["The Beatles"],
    "album" => "Abbey Road",
    "release_year" => 1969,
    # Enrichment data added:
    "song_id" => 456,
    "song_name" => "Come Together",
    "opensearch_match" => true,
    "opensearch_score" => 18.5
  }
}
```

### Example 2: MusicBrainz Fallback (No Local Match)

**Input** (ListItem):
```ruby
{
  metadata: {
    "title" => "Rare B-Side Track",
    "artists" => ["Obscure Artist"]
  }
}
```

**OpenSearch Response**: `[]` (no match)

**MusicBrainz Response**:
```ruby
{
  success: true,
  data: {
    "recordings" => [{
      "id" => "abc123-def456",
      "title" => "Rare B-Side Track",
      "artist-credit" => [
        {"artist" => {"id" => "artist-mbid-123", "name" => "Obscure Artist"}}
      ]
    }]
  }
}
```

**Song Lookup**: `Music::Song.with_identifier(:music_musicbrainz_recording_id, "abc123-def456")` returns `nil`

**Output** (ListItem after enrichment):
```ruby
{
  listable_id: nil,  # Still nil - no local song
  metadata: {
    "title" => "Rare B-Side Track",
    "artists" => ["Obscure Artist"],
    # Enrichment data added:
    "mb_recording_id" => "abc123-def456",
    "mb_recording_name" => "Rare B-Side Track",
    "mb_artist_ids" => ["artist-mbid-123"],
    "mb_artist_names" => ["Obscure Artist"],
    "musicbrainz_match" => true
  }
}
```

### Example 3: No Match Found

**Input** (ListItem):
```ruby
{
  metadata: {
    "title" => "My Custom Song",
    "artists" => ["Unknown Artist"]
  }
}
```

**OpenSearch Response**: `[]`

**MusicBrainz Response**:
```ruby
{success: true, data: {"recordings" => []}}
```

**Output** (ListItem after enrichment):
```ruby
{
  listable_id: nil,
  metadata: {
    "title" => "My Custom Song",
    "artists" => ["Unknown Artist"]
    # No enrichment data added - item remains as-is
  }
}
```

**Service Result**:
```ruby
{success: false, source: :not_found, data: {}}
```

### Example 4: Final Job Stats

**After processing 100 items**:
```ruby
list.wizard_job_metadata
# => {
#   "processed_items" => 100,
#   "total_items" => 100,
#   "opensearch_matches" => 60,
#   "musicbrainz_matches" => 25,
#   "not_found" => 15,
#   "enriched_at" => "2025-01-23T15:30:45Z"
# }
```

---

## Technical Approach

### File Structure

```
web-app/
+-- app/
|   +-- sidekiq/
|   |   +-- music/
|   |       +-- songs/
|   |           +-- wizard_enrich_list_items_job.rb    # NEW: Background job
|   +-- lib/
|   |   +-- services/
|   |       +-- lists/
|   |           +-- music/
|   |               +-- songs/
|   |                   +-- list_item_enricher.rb       # NEW: Single item enricher
|   +-- controllers/
|   |   +-- admin/
|   |       +-- music/
|   |           +-- songs/
|   |               +-- list_wizard_controller.rb       # MODIFY: Add enrich logic
|   +-- components/
|       +-- admin/
|           +-- music/
|               +-- songs/
|                   +-- wizard/
|                       +-- enrich_step_component.rb     # MODIFY: Add logic
|                       +-- enrich_step_component.html.erb # MODIFY: Full UI
+-- test/
    +-- sidekiq/
    |   +-- music/
    |       +-- songs/
    |           +-- wizard_enrich_list_items_job_test.rb  # NEW: Job tests
    +-- lib/
    |   +-- services/
    |       +-- lists/
    |           +-- music/
    |               +-- songs/
    |                   +-- list_item_enricher_test.rb     # NEW: Service tests
    +-- controllers/
    |   +-- admin/
    |       +-- music/
    |           +-- songs/
    |               +-- list_wizard_controller_test.rb    # MODIFY: Add enrich tests
    +-- components/
        +-- admin/
            +-- music/
                +-- songs/
                    +-- wizard/
                        +-- enrich_step_component_test.rb # NEW: Component tests
```

---

## Key Implementation Files

### 1. Single Item Enricher Service

**File**: `app/lib/services/lists/music/songs/list_item_enricher.rb` (NEW)

**Reference Pattern**: `app/lib/services/lists/music/songs/items_json_enricher.rb` (lines 64-150)

**Implementation** (reference only, ~60 lines):

```ruby
module Services
  module Lists
    module Music
      module Songs
        class ListItemEnricher
          def self.call(list_item:)
            new(list_item: list_item).call
          end

          def initialize(list_item:)
            @list_item = list_item
          end

          def call
            title = @list_item.metadata["title"]
            artists = @list_item.metadata["artists"]

            return not_found_result if title.blank? || artists.blank?

            # Try OpenSearch first (fast local lookup)
            opensearch_result = find_via_opensearch(title, artists)
            return opensearch_result if opensearch_result[:success]

            # Fall back to MusicBrainz (slower external API)
            musicbrainz_result = find_via_musicbrainz(title, artists)
            return musicbrainz_result if musicbrainz_result[:success]

            not_found_result
          rescue => e
            Rails.logger.error "ListItemEnricher failed: #{e.message}"
            {success: false, source: :error, error: e.message, data: {}}
          end

          private

          # ... private methods for OpenSearch and MusicBrainz lookups
          # See items_json_enricher.rb lines 122-150 for patterns
        end
      end
    end
  end
end
```

### 2. Background Job

**File**: `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb` (NEW)

**Reference Pattern**: `app/sidekiq/music/songs/wizard_parse_list_job.rb`

**Implementation** (reference only, ~70 lines):

```ruby
class Music::Songs::WizardEnrichListItemsJob
  include Sidekiq::Job

  PROGRESS_UPDATE_INTERVAL = 10

  def perform(list_id)
    @list = Music::Songs::List.find(list_id)
    @items = @list.list_items.unverified.ordered
    @total = @items.count

    if @total.zero?
      handle_error("No items to enrich")
      return
    end

    @list.update_wizard_job_status(status: "running", progress: 0)
    clear_previous_enrichment_data

    stats = {opensearch_matches: 0, musicbrainz_matches: 0, not_found: 0}

    @items.each_with_index do |item, index|
      result = Services::Lists::Music::Songs::ListItemEnricher.call(list_item: item)

      case result[:source]
      when :opensearch then stats[:opensearch_matches] += 1
      when :musicbrainz then stats[:musicbrainz_matches] += 1
      else stats[:not_found] += 1
      end

      update_progress(index + 1, stats) if should_update_progress?(index)
    end

    complete_job(stats)
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "WizardEnrichListItemsJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WizardEnrichListItemsJob failed: #{e.message}"
    handle_error(e.message)
    raise
  end

  private

  # ... helper methods for progress updates, error handling
end
```

### 3. Enrich Step Component Template

**File**: `app/components/admin/music/songs/wizard/enrich_step_component.html.erb` (MODIFY)

**Pattern Reference**: `parse_step_component.html.erb`

**Key UI Elements**:
- Stats cards (DaisyUI stat component)
- Progress bar with Stimulus targets
- Item preview table (scrollable)
- Conditional Stimulus controller attachment
- State-based button display

### 4. Controller Modifications

**File**: `app/controllers/admin/music/songs/list_wizard_controller.rb` (MODIFY)

**Changes**:
1. Implement `load_enrich_step_data` (line 89-90)
2. Implement `enqueue_enrich_job` (line 109-110)
3. Add `advance_from_enrich_step` method
4. Update `advance_step` to handle "enrich" case

---

## Testing Strategy

### Service Tests

**File**: `test/lib/services/lists/music/songs/list_item_enricher_test.rb` (NEW)

**Test Cases**:
```ruby
test "returns opensearch result when local song found"
test "returns musicbrainz result when opensearch finds nothing"
test "returns not_found when neither source matches"
test "updates list_item.listable_id when song found via OpenSearch"
test "updates list_item.listable_id when song found via MusicBrainz MBID"
test "updates list_item.metadata with enrichment data"
test "handles missing title gracefully"
test "handles missing artists gracefully"
test "handles OpenSearch errors gracefully"
test "handles MusicBrainz errors gracefully"
```

### Job Tests

**File**: `test/sidekiq/music/songs/wizard_enrich_list_items_job_test.rb` (NEW)

**Test Cases**:
```ruby
test "job updates wizard_state to running at start"
test "job enriches all unverified items"
test "job updates progress every 10 items"
test "job updates wizard_state to completed with final stats"
test "job updates wizard_state to failed on error"
test "job is idempotent - clears previous enrichment data"
test "job handles empty list gracefully"
test "job continues processing after individual item failure"
test "job tracks opensearch vs musicbrainz match counts"
test "job raises error when list not found"
```

### Component Tests

**File**: `test/components/admin/music/songs/wizard/enrich_step_component_test.rb` (NEW)

**Test Cases**:
```ruby
test "renders stats cards"
test "renders progress bar with current progress"
test "renders Start Enrichment button when job idle"
test "does not render Start Enrichment button when job running"
test "renders error message when job failed"
test "uses wizard-step controller when job is running"
test "does not use wizard-step controller when job is idle"
test "displays item preview table when completed"
test "shows correct match percentages in stats"
```

### Controller Tests

**File**: `test/controllers/admin/music/songs/list_wizard_controller_test.rb` (MODIFY)

**Add Test Cases**:
```ruby
test "enrich step loads item counts"
test "advancing from enrich step enqueues job when idle"
test "advancing from enrich step proceeds when job completed"
test "advancing from enrich step blocks when job running"
```

---

## Behavioral Rules

### Job Execution Rules

1. **Idempotency**: Job can be safely retried
   - Clear enrichment-specific metadata fields before processing
   - Set `listable_id = nil` for items being re-enriched

2. **Progress Updates**: wizard_state updated at key milestones
   - Start: `{status: "running", progress: 0}`
   - Every 10 items: `{progress: N%, metadata: {processed_items: X, ...}}`
   - Complete: `{status: "completed", progress: 100, metadata: {final stats}}`
   - Failure: `{status: "failed", error: "message"}`

3. **Error Recovery**: Individual item failures don't stop job
   - Log warning for failed item
   - Increment `not_found` counter
   - Continue to next item

### UI Polling Rules

1. **Auto-Start**: Polling starts if job_status is "running" on page load
2. **Auto-Stop**: Polling stops when job_status is "completed" or "failed"
3. **Turbo Refresh**: Frame refreshes when job completes (shows final stats)
4. **Button States**:
   - "Start Enrichment": Visible when status is "idle" or "failed"
   - Continue button: Enabled only when status is "completed"

### Navigation Rules

1. **Cannot Skip**: Cannot advance to validate step until enrichment completes
2. **Can Retry**: Can restart enrichment if it failed
3. **Can Go Back**: Can return to parse step (preserves list_items)

---

## Implementation Steps

### Phase 1: Service Object (Estimated: 2 hours)

1. **Create service file**
   - [ ] Generate file: `app/lib/services/lists/music/songs/list_item_enricher.rb`
   - [ ] Define `self.call(list_item:)` class method
   - [ ] Implement OpenSearch lookup (copy from items_json_enricher)
   - [ ] Implement MusicBrainz fallback (copy from items_json_enricher)
   - [ ] Add metadata update logic
   - [ ] Add listable_id update logic

2. **Write service tests**
   - [ ] Create test file: `test/lib/services/lists/music/songs/list_item_enricher_test.rb`
   - [ ] Test OpenSearch match path
   - [ ] Test MusicBrainz fallback path
   - [ ] Test no match path
   - [ ] Test error handling
   - [ ] Run tests: `bin/rails test test/lib/services/lists/music/songs/list_item_enricher_test.rb`

### Phase 2: Background Job (Estimated: 2 hours)

3. **Create job file**
   - [ ] Generate file: `bin/rails generate sidekiq:job music/songs/wizard_enrich_list_items`
   - [ ] Implement `perform(list_id)` method
   - [ ] Add progress tracking logic
   - [ ] Add stats collection
   - [ ] Add error handling

4. **Write job tests**
   - [ ] Test successful enrichment flow
   - [ ] Test progress updates
   - [ ] Test error handling
   - [ ] Test idempotency
   - [ ] Run tests: `bin/rails test test/sidekiq/music/songs/wizard_enrich_list_items_job_test.rb`

### Phase 3: View Component (Estimated: 1.5 hours)

5. **Update enrich step component**
   - [ ] Update `enrich_step_component.rb` with parameters
   - [ ] Update `enrich_step_component.html.erb` with full UI
   - [ ] Add stats cards
   - [ ] Add progress bar with Stimulus targets
   - [ ] Add item preview table
   - [ ] Add conditional Stimulus controller attachment

6. **Write component tests**
   - [ ] Create test file: `test/components/admin/music/songs/wizard/enrich_step_component_test.rb`
   - [ ] Test all UI states
   - [ ] Run tests

### Phase 4: Controller Integration (Estimated: 1 hour)

7. **Update controller**
   - [ ] Implement `load_enrich_step_data`
   - [ ] Implement `enqueue_enrich_job`
   - [ ] Add `advance_from_enrich_step` method
   - [ ] Update `advance_step` case statement

8. **Write controller tests**
   - [ ] Test data loading
   - [ ] Test job enqueue
   - [ ] Test step advancement
   - [ ] Run tests

### Phase 5: Integration Testing (Estimated: 1 hour)

9. **Manual browser testing**
   - [ ] Start Rails server and Sidekiq
   - [ ] Create test list and run through wizard
   - [ ] Verify progress updates work
   - [ ] Verify stats display correctly
   - [ ] Test error case (disconnect network mid-enrichment)
   - [ ] Test retry after failure

10. **Full test suite**
    - [ ] Run all wizard tests
    - [ ] Verify 0 failures
    - [ ] Fix any integration issues

---

## Validation Checklist (Definition of Done)

- [ ] Service object exists and tested (10+ tests passing)
- [ ] Service enriches via OpenSearch and MusicBrainz
- [ ] Service updates metadata and listable_id correctly
- [ ] Background job exists and tested (10+ tests passing)
- [ ] Job processes all unverified items
- [ ] Job updates wizard_state with progress
- [ ] Job is idempotent
- [ ] View component renders all UI states
- [ ] Component tests pass (10+ tests)
- [ ] Controller enqueues job correctly
- [ ] Controller blocks advance until job complete
- [ ] Controller tests pass (4+ new tests)
- [ ] Polling updates progress in real-time
- [ ] Stats display correctly after completion
- [ ] Error messages display correctly
- [ ] Navigation flow works end-to-end
- [ ] All tests pass (34+ new tests total)
- [ ] No N+1 queries introduced
- [ ] Documentation updated

---

## Dependencies

### Depends On (Completed)
- [086] Infrastructure - wizard_state, routes, model helpers
- [087] Wizard UI Shell - WizardController, polling Stimulus controller
- [088] Step 0: Import Source - import_source selection
- [089] Step 1: Parse - Creates unverified list_items with metadata

### Needed By (Blocked Until This Completes)
- [091] Step 3: Validation - Requires enriched list_items to validate
- [092] Step 4: Review UI - Requires enriched list_items to display
- [094] Step 5: Import - Requires MusicBrainz IDs for creating new songs

### External References
- **Existing Enricher**: `app/lib/services/lists/music/songs/items_json_enricher.rb` (lines 1-177)
- **OpenSearch Search**: `app/lib/search/music/search/song_by_title_and_artists.rb` (lines 1-82)
- **MusicBrainz Search**: `app/lib/music/musicbrainz/search/recording_search.rb` (lines 1-240)
- **ListItem Model**: `app/models/list_item.rb` (lines 1-70)
- **Parse Job Pattern**: `app/sidekiq/music/songs/wizard_parse_list_job.rb` (lines 1-70)

---

## Related Tasks

- **Previous**: [089] Song Step 1: Parse HTML
- **Next**: [091] Song Step 3: Validation
- **Reference**: Existing enricher (adapt patterns, don't duplicate)

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns (Sidekiq jobs, ViewComponents, polling)
- Do not duplicate authoritative code; **link to files by path**
- Respect snippet budget (<=40 lines per snippet)
- Reuse OpenSearch and MusicBrainz patterns from `items_json_enricher.rb`
- Update wizard_state atomically at all stages
- Make job idempotent (can retry safely)

### Required Outputs
- New file: `app/lib/services/lists/music/songs/list_item_enricher.rb`
- New file: `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb`
- New file: `test/lib/services/lists/music/songs/list_item_enricher_test.rb`
- New file: `test/sidekiq/music/songs/wizard_enrich_list_items_job_test.rb`
- New file: `test/components/admin/music/songs/wizard/enrich_step_component_test.rb`
- Modified: `app/components/admin/music/songs/wizard/enrich_step_component.rb`
- Modified: `app/components/admin/music/songs/wizard/enrich_step_component.html.erb`
- Modified: `app/controllers/admin/music/songs/list_wizard_controller.rb`
- Modified: `test/controllers/admin/music/songs/list_wizard_controller_test.rb`
- Passing tests for all new functionality (34+ tests)
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1. **codebase-pattern-finder** -> Collect enricher patterns (already done in spec creation)
2. **codebase-analyzer** -> Verify data flow & integration points (already done)
3. **technical-writer** -> Update docs after implementation

### Test Fixtures
- Use existing `lists(:music_songs_list)` fixture
- Use existing `music_songs(:time)` fixture for OpenSearch match tests
- Mock OpenSearch and MusicBrainz responses in tests (use `stubs`)

---

## Implementation Notes

### Files Created
- `app/lib/services/lists/music/songs/list_item_enricher.rb` - Single item enrichment service
- `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb` - Background job for batch enrichment
- `test/lib/services/lists/music/songs/list_item_enricher_test.rb` - 13 service tests
- `test/sidekiq/music/songs/wizard_enrich_list_items_job_test.rb` - 10 job tests
- `test/components/admin/music/songs/wizard/enrich_step_component_test.rb` - 15 component tests

### Files Modified
- `app/components/admin/music/songs/wizard/enrich_step_component.rb` - Added helper methods for stats and state
- `app/components/admin/music/songs/wizard/enrich_step_component.html.erb` - Full UI with 4 states
- `app/controllers/admin/music/songs/list_wizard_controller.rb` - Added enrich step logic
- `test/controllers/admin/music/songs/list_wizard_controller_test.rb` - Added 6 new controller tests

### Key Implementation Details
- Service uses `artists.join(", ")` for MusicBrainz search (matches existing `ItemsJsonEnricher` pattern)
- Added comprehensive logging for MusicBrainz calls to aid debugging
- Preview table shows all items (not limited to 10) with scrollable container
- Job resets previous enrichment data before re-enriching (idempotent)
- Job status reset to "idle" when advancing between steps

### Test Coverage
- 60 new/modified tests all passing
- 2305 total tests passing

---

## Deviations from Plan

1. **Preview Table**: Changed from showing 10 items to showing all items with a scrollable container (`max-h-[32rem]`) for better visibility
2. **Added Logging**: Added detailed INFO/WARN/ERROR logging for MusicBrainz calls to aid debugging connection issues
3. **Job Status Reset**: Added explicit reset of job status when advancing from parse step to enrich step (not originally specified)

---

## Documentation Updated

- [x] This task file updated with implementation notes
- [x] Cross-references updated in related task files
- [x] Service documentation created at `docs/lib/services/lists/music/songs/list_item_enricher.md`
- [x] Job documentation created at `docs/sidekiq/music/songs/wizard_enrich_list_items_job.md`

---

## Notes

### Performance Considerations
- OpenSearch queries are fast (~10ms) - prefer these
- MusicBrainz API has rate limits (~1 request/second) - batch appropriately
- Progress updates add I/O overhead - batch every 10 items
- Use `find_each` if processing > 1000 items (not expected in MVP)

### Security Considerations
- Job runs in background worker (no direct user input in job)
- List ID validated by ActiveRecord (raises if not found)
- wizard_state updates use ActiveRecord (prevents SQL injection)
- External API responses sanitized before storage

### Future Enhancements (Out of Scope)
- [ ] Parallel enrichment (multiple workers)
- [ ] Configurable min_score threshold
- [ ] Manual match selection UI
- [ ] Batch import of unmatched songs from MusicBrainz

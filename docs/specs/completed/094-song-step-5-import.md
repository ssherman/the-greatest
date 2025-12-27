# [094] - Song Wizard: Step 5 - Import & Complete

## Status
- **Status**: Complete
- **Priority**: High
- **Created**: 2025-01-19
- **Completed**: 2025-12-10
- **Part**: 9 of 10

## Overview
Import songs from MusicBrainz based on the wizard's import source. This step handles **two paths**:

1. **Custom HTML Path**: Import individual songs for items that have `mb_recording_id` in metadata but no linked `Music::Song`
2. **MusicBrainz Series Path**: Import all songs from the list's `musicbrainz_series_id` using the existing series importer

After import, songs are linked to `list_items` and marked as verified. This is the final data processing step before wizard completion.

## Context

This is **Part 9 of 10** in the Song List Wizard implementation:

1. [086] Infrastructure - Complete
2. [087] Wizard UI Shell - Complete
3. [088] Step 0: Import Source Choice - Complete
4. [089] Step 1: Parse HTML - Complete
5. [090] Step 2: Enrich - Complete
6. [090a] Step-Namespaced Status - Complete
7. [091] Step 3: Validation - Complete
8. [092] Step 4: Review UI - Complete
9. [093] Step 4: Actions - Complete
10. **[094] Step 5: Import** - You are here
11. [095] Polish & Integration

### The Flow

**Custom HTML Path** (full wizard):
```
Step 0 (source) -> Step 1 (parse) -> Step 2 (enrich) -> Step 3 (validate) -> Step 4 (review) -> Step 5 (import) -> Complete
```

**MusicBrainz Series Path** (shortcut - skips to import):
```
Step 0 (source) -> Step 5 (import) -> Complete
```

When user selects "MusicBrainz Series" at Step 0, the wizard jumps directly to Step 5 (import) since all the song data comes from the MusicBrainz series API.

### What This Builds

This task implements:
- **Import step view component** with:
  - **Custom HTML path**: Summary of items to import, already linked, and without match
  - **MusicBrainz Series path**: Series info display and "Import from Series" button
  - Progress bar during import (both paths)
  - Results summary after completion
- **Background job** (`Music::Songs::WizardImportSongsJob`) that handles BOTH paths:
  - **Custom HTML path**: Import individual items with `mb_recording_id`
  - **MusicBrainz Series path**: Delegate to existing `DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries`
  - Track progress and errors for both paths
- **Controller logic** to enqueue job and handle step advancement
- **Component and controller tests**

This task does NOT implement:
- Bulk re-import of existing songs
- Import retry for individual failed items (deferred to [095] Polish)

### Key Design Decisions

**Single Job Handles Both Paths**:
- **Decision**: `Music::Songs::WizardImportSongsJob` checks `import_source` and dispatches accordingly
- **Why**:
  - Unified progress tracking and error handling
  - Single controller flow regardless of import source
  - Reuses existing `DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries` for series path
  - Custom HTML path uses `DataImporters::Music::Song::Importer` per item

**MusicBrainz Series Path - Reuse Existing Code**:
- **Decision**: Delegate to existing `ImportSongsFromMusicbrainzSeries` service
- **Why**:
  - Service already handles: API calls, song imports, list_item creation, duplicate detection
  - Well-tested and production-ready
  - Only need to wrap with wizard progress tracking

**Custom HTML Path - Individual Item Import**:
- **Decision**: Import each item individually using `DataImporters::Music::Song::Importer`
- **Why**:
  - Items have their own `mb_recording_id` from enrichment/manual linking
  - Individual imports allow per-item error handling
  - Follows existing pattern from `Services::Lists::Music::Songs::ItemsJsonImporter`

**Always Link and Verify on Success**:
- **Decision**: After successful import, set `listable_id` AND `verified = true`
- **Why**:
  - Song was just imported from authoritative MusicBrainz data
  - No need for additional AI validation (MBID is exact match)
  - Matches behavior of `link_musicbrainz` action in [093]

**Skip Already-Linked Items (Custom HTML Path Only)**:
- **Decision**: Only import items where `listable_id` is nil
- **Why**:
  - Items with `listable_id` are already linked (from OpenSearch match or manual link)
  - Re-importing would be wasteful
  - Series path creates all items fresh (no pre-existing items)

**Progress Tracking Pattern**:
- Use `list.update_wizard_step_status(step: "import", ...)` helper
- Custom HTML: Granular progress (every 10 items or 5 seconds)
- Series: Wrap service call with start/complete status updates
- Metadata includes: `imported_count`, `skipped_count`, `failed_count`, `errors`, `import_source`

---

## Requirements

### Functional Requirements

#### FR-1: Import Step View Component
**Contract**: Display import summary based on `import_source`, trigger import job, show progress and results

The component renders differently based on `list.wizard_state["import_source"]`:

**Custom HTML Path UI** (`import_source == "custom_html"`):

**State 1 - Idle (Ready to Import)**:
- Stats cards showing:
  - Total items in list
  - Items already linked (have `listable_id`)
  - Items to import (have `mb_recording_id`, no `listable_id`)
  - Items without match (no `mb_recording_id`, no `listable_id`)
- Info alert explaining what import does
- "Start Import" button (enabled if items to import > 0)
- Preview table of items to import (title, artists, MB recording name)

**State 2 - Running**:
- Progress bar (0-100%)
- Status text: "Importing songs from MusicBrainz..."
- Animated loading indicator
- Stats: "Imported X of Y items"
- "Start Import" button disabled

**State 3 - Completed**:
- Success message: "Import Complete!"
- Stats cards showing:
  - Imported successfully (count)
  - Skipped (already existed) (count)
  - Failed (count with error details)
- "View Failed Items" expandable section if any failures
- "Complete Wizard" button to proceed to completion step

**State 4 - Failed**:
- Error message with details
- "Retry Import" button
- List of failed items with error messages

---

**MusicBrainz Series Path UI** (`import_source == "musicbrainz_series"`):

**State 1 - Idle (Ready to Import)**:
- Series info card showing:
  - Series ID: `list.musicbrainz_series_id`
  - List name
- Info alert: "This will import all songs from the MusicBrainz series and create list items automatically."
- "Import from Series" button

**State 2 - Running**:
- Progress bar (indeterminate or 0% -> 100%)
- Status text: "Importing songs from MusicBrainz series..."
- Animated loading indicator
- "Import from Series" button disabled

**State 3 - Completed**:
- Success message: "Series Import Complete!"
- Stats cards showing:
  - Songs imported (count)
  - List items created (count)
  - Failed (count)
- "View Results" expandable section showing imported songs
- "Complete Wizard" button to proceed to completion step

**State 4 - Failed**:
- Error message with details
- "Retry Import" button

---

**Stimulus Controller Integration**:
- Uses existing `wizard_step_controller.js`
- Targets: `progressBar`, `statusText`
- Conditionally attached only when job is "running"

**Implementation**:
- `app/components/admin/music/songs/wizard/import_step_component.rb`
- `app/components/admin/music/songs/wizard/import_step_component.html.erb`

#### FR-2: Background Job for Import
**Contract**: Import songs based on `import_source` - either from series or individual items

**Job Specification**:
- **File**: `app/sidekiq/music/songs/wizard_import_songs_job.rb`
- **Queue**: `default`
- **Parameters**: `list_id` (integer)

**Job Workflow** (dispatches based on `import_source`):

```ruby
def perform(list_id)
  @list = Music::Songs::List.find(list_id)
  import_source = @list.wizard_state&.[]("import_source")

  if import_source == "musicbrainz_series"
    import_from_series
  else
    import_from_custom_html
  end
end
```

**MusicBrainz Series Path** (`import_source == "musicbrainz_series"`):
1. Update wizard_step_status: `{status: "running", progress: 0}`
2. Call `DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.call(list: @list)`
3. Extract results from service response
4. Update wizard_step_status: `{status: "completed", progress: 100, metadata: {stats from service}}`

**Custom HTML Path** (`import_source == "custom_html"` or default):
1. Get items to import: `list.list_items.where(listable_id: nil).where("metadata->>'mb_recording_id' IS NOT NULL")`
2. Update wizard_step_status: `{status: "running", progress: 0}`
3. For each item:
   a. Call `DataImporters::Music::Song::Importer.call(musicbrainz_recording_id: item.metadata["mb_recording_id"])`
   b. If success: Update `item.listable = result.item`, `item.verified = true`
   c. If failure: Store error in `item.metadata["import_error"]`
   d. Update progress periodically
4. Update wizard_step_status: `{status: "completed", progress: 100, metadata: {stats}}`

**Error Handling**:
- Series path: Service-level errors mark job as failed
- Custom HTML path: Individual item failures don't stop the job, track in metadata
- Job-level errors (database issues) mark job as failed
- Empty list (no items to import) completes immediately with zero counts

**Implementation Pattern**: Reference `wizard_enrich_list_items_job.rb` for progress tracking

#### FR-3: Controller Integration
**Contract**: Enqueue import job and handle step advancement

**Method Updates**:

1. **`load_import_step_data`**:
   ```ruby
   def load_import_step_data
     @all_items = @list.list_items.ordered
     @linked_items = @all_items.where.not(listable_id: nil)
     @items_to_import = @all_items.where(listable_id: nil)
       .where("metadata->>'mb_recording_id' IS NOT NULL")
     @items_without_match = @all_items.where(listable_id: nil)
       .where("metadata->>'mb_recording_id' IS NULL")
   end
   ```

2. **`enqueue_import_job`**:
   ```ruby
   def enqueue_import_job
     Music::Songs::WizardImportSongsJob.perform_async(wizard_entity.id)
   end
   ```

3. **`advance_from_import_step`**:
   - Similar pattern to `advance_from_validate_step`
   - If idle/failed: Set status to "running", enqueue job, redirect to import step
   - If completed: Advance to complete step
   - If running: Show "in progress" alert

**Implementation Location**: `app/controllers/admin/music/songs/list_wizard_controller.rb`

---

### Non-Functional Requirements

#### NFR-1: Performance
- [ ] Import job completes in < 2 minutes for lists with < 100 items
- [ ] Progress updates every 10 items or 5 seconds (whichever is first)
- [ ] MusicBrainz API rate limiting respected (1 request/second)
- [ ] No N+1 queries in component rendering

#### NFR-2: Data Integrity
- [ ] Job is idempotent (re-running imports missing items, skips existing)
- [ ] Failed imports don't affect other items
- [ ] wizard_state updates are atomic
- [ ] Import errors stored per-item in metadata

#### NFR-3: Error Handling
- [ ] MusicBrainz API timeout handled gracefully (per item)
- [ ] Network errors logged and stored per item
- [ ] Empty result (no items to import) handled gracefully
- [ ] Duplicate song detection (finder returns existing)

#### NFR-4: Observability
- [ ] Job start/completion logged with metadata
- [ ] Each import attempt logged with result
- [ ] Final stats logged at info level
- [ ] Errors include full context for debugging

---

## Contracts & Schemas

### ListItem Metadata Schema (After Import)

**Fields added on successful import**:
```json
{
  "imported_at": "2025-01-23T15:30:45Z",
  "imported_song_id": 456
}
```

**Fields added on failed import**:
```json
{
  "import_error": "MusicBrainz API timeout",
  "import_attempted_at": "2025-01-23T15:30:45Z"
}
```

### Endpoint Table

| Verb | Path | Purpose | Params/Body | Auth | Response |
|------|------|---------|-------------|------|----------|
| GET | `/wizard/step/import` | Show import step | - | admin | HTML (Turbo Frame) |
| POST | `/wizard/step/import/advance` | Start import job or advance | step="import" | admin | 302 redirect |
| GET | `/wizard/step/import/status` | Get job status | step="import" | admin | JSON |

### Status Endpoint Response

**Endpoint**: `GET /admin/songs/lists/:list_id/wizard/step_status?step=import`

**Response** (running):
```json
{
  "status": "running",
  "progress": 45,
  "error": null,
  "metadata": {
    "processed_items": 45,
    "total_items": 100,
    "imported_count": 40,
    "skipped_count": 3,
    "failed_count": 2
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
    "imported_count": 85,
    "skipped_count": 10,
    "failed_count": 5,
    "errors": [
      {"item_id": 123, "error": "MusicBrainz recording not found"},
      {"item_id": 456, "error": "API timeout"}
    ],
    "imported_at": "2025-01-23T15:35:00Z"
  }
}
```

### Wizard State Update

**Before** (after review step):
```json
{
  "current_step": 5,
  "import_source": "custom_html",
  "steps": {
    "parse": { "status": "completed", ... },
    "enrich": { "status": "completed", ... },
    "validate": { "status": "completed", ... },
    "review": { "status": "completed", ... },
    "import": {
      "status": "idle",
      "progress": 0,
      "error": null,
      "metadata": {}
    }
  }
}
```

**After successful import**:
```json
{
  "current_step": 5,
  "steps": {
    "import": {
      "status": "completed",
      "progress": 100,
      "error": null,
      "metadata": {
        "imported_count": 85,
        "skipped_count": 10,
        "failed_count": 5,
        "imported_at": "2025-01-23T15:35:00Z"
      }
    }
  }
}
```

---

## Acceptance Criteria

### View Component - Common
- [ ] `Admin::Music::Songs::Wizard::ImportStepComponent` renders based on `import_source`
- [ ] Progress bar exists with `data-wizard-step-target="progressBar"` attribute
- [ ] Status text exists with `data-wizard-step-target="statusText"` attribute
- [ ] Error display area shown when job failed
- [ ] Uses Stimulus controller conditionally (only when running)

### View Component - Custom HTML Path
- [ ] Stats cards show: Total items, Already linked, To import, Without match
- [ ] "Start Import" button exists when job idle/failed
- [ ] "Start Import" button disabled when no items to import
- [ ] Results summary shows imported/skipped/failed counts
- [ ] Failed items list expandable if failures exist
- [ ] Preview table shows items to import

### View Component - MusicBrainz Series Path
- [ ] Series info card shows `musicbrainz_series_id`
- [ ] "Import from Series" button exists when job idle/failed
- [ ] Results summary shows songs imported/list items created/failed
- [ ] "View Results" expandable section showing imported songs

### Background Job - Common
- [ ] `Music::Songs::WizardImportSongsJob` exists in correct namespace
- [ ] Job updates wizard_step_status to "running" at start
- [ ] Job updates wizard_step_status to "completed" with stats on success
- [ ] Job dispatches based on `import_source` in wizard_state
- [ ] Job is idempotent (can retry safely)

### Background Job - Custom HTML Path
- [ ] Job processes only items with `mb_recording_id` AND `listable_id` nil
- [ ] Job calls `DataImporters::Music::Song::Importer` for each item
- [ ] Job sets `listable_id` on successful import
- [ ] Job sets `verified = true` on successful import
- [ ] Job stores import error in metadata on failure
- [ ] Job updates progress periodically (every 10 items or 5 seconds)
- [ ] Job handles empty list gracefully (0 items to import)
- [ ] Job skips items where song already exists (importer returns existing)

### Background Job - MusicBrainz Series Path
- [ ] Job calls `DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries`
- [ ] Job extracts stats from service result
- [ ] Job handles service failure gracefully
- [ ] Job stores results in wizard_step_metadata

### Controller Logic
- [ ] `load_import_step_data` loads data based on `import_source`
- [ ] `enqueue_import_job` calls the Sidekiq job
- [ ] `advance_from_import_step` implemented with correct pattern
- [ ] Cannot advance if job not completed
- [ ] Can advance to complete step when job completed
- [ ] Flash alert shown if trying to advance prematurely

### Data Integrity
- [ ] Imported songs linked to list_items correctly
- [ ] `listable_type` set to "Music::Song"
- [ ] `verified = true` set on imported items (custom HTML path)
- [ ] Series import creates list_items with correct positions
- [ ] Failed items retain their metadata (no data loss)
- [ ] Duplicate detection works (existing songs reused, not duplicated)

### Tests
- [ ] Job tests cover Custom HTML path (10+ tests)
- [ ] Job tests cover MusicBrainz Series path (5+ tests)
- [ ] Component tests cover both paths (15+ tests)
- [ ] Controller tests cover step logic (5+ tests)

---

## Golden Examples

### Example 1: Successful Import Flow

**Input** (ListItems after review step):
```ruby
# Item 1: Already linked (skip during import)
ListItem.new(
  position: 1,
  listable_id: 123,  # Already linked
  verified: true,
  metadata: {
    "title" => "Come Together",
    "artists" => ["The Beatles"],
    "song_id" => 123
  }
)

# Item 2: Has MB ID, needs import
ListItem.new(
  position: 2,
  listable_id: nil,  # Not linked
  verified: true,    # AI validated
  metadata: {
    "title" => "Imagine",
    "artists" => ["John Lennon"],
    "mb_recording_id" => "a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
    "mb_recording_name" => "Imagine",
    "musicbrainz_match" => true
  }
)

# Item 3: No match at all (skip during import)
ListItem.new(
  position: 3,
  listable_id: nil,
  verified: false,
  metadata: {
    "title" => "Obscure B-Side",
    "artists" => ["Unknown Artist"]
  }
)
```

**Import Job Processing**:
1. Skips Item 1 (already has `listable_id`)
2. Imports Item 2:
   - Calls `DataImporters::Music::Song::Importer.call(musicbrainz_recording_id: "a1b2c3d4...")`
   - Result: `{success: true, item: Music::Song(id: 456)}`
   - Updates: `item.listable = song, item.verified = true`
3. Skips Item 3 (no `mb_recording_id`)

**Output** (ListItems after import):
```ruby
# Item 1: Unchanged
ListItem(
  listable_id: 123,
  verified: true,
  metadata: { ... }
)

# Item 2: Now linked!
ListItem(
  listable_id: 456,  # NEW - linked to imported song
  verified: true,
  metadata: {
    "title" => "Imagine",
    "mb_recording_id" => "a1b2c3d4...",
    "imported_at" => "2025-01-23T15:30:45Z",
    "imported_song_id" => 456
  }
)

# Item 3: Unchanged
ListItem(
  listable_id: nil,
  verified: false,
  metadata: { ... }
)
```

**Final wizard_step_metadata**:
```json
{
  "imported_count": 1,
  "skipped_count": 0,
  "failed_count": 0,
  "imported_at": "2025-01-23T15:30:45Z"
}
```

### Example 2: Import with Existing Song (Finder Returns Match)

**Input**:
```ruby
ListItem.new(
  listable_id: nil,
  metadata: {
    "title" => "Time",
    "mb_recording_id" => "existing-mbid-123"
  }
)
```

**Import Process**:
1. Calls `DataImporters::Music::Song::Importer.call(musicbrainz_recording_id: "existing-mbid-123")`
2. Finder finds existing song with matching MBID
3. Result: `{success: true, item: Music::Song(id: 789), provider_results: []}` (no providers run)
4. Updates: `item.listable_id = 789, item.verified = true`

**Key Behavior**: Importer's finder detects existing song, returns it without re-importing.

### Example 3: Import with API Failure (Custom HTML Path)

**Input**:
```ruby
ListItem.new(
  id: 999,
  listable_id: nil,
  metadata: {
    "title" => "Rare Song",
    "mb_recording_id" => "nonexistent-mbid"
  }
)
```

**Import Process**:
1. Calls `DataImporters::Music::Song::Importer.call(musicbrainz_recording_id: "nonexistent-mbid")`
2. MusicBrainz API returns 404 (recording not found)
3. Result: `{success: false, all_errors: ["Recording not found"]}`
4. Updates: `item.metadata["import_error"] = "Recording not found"`

**Output**:
```ruby
ListItem(
  listable_id: nil,  # Still not linked
  verified: true,    # Unchanged
  metadata: {
    "title" => "Rare Song",
    "mb_recording_id" => "nonexistent-mbid",
    "import_error" => "Recording not found",
    "import_attempted_at" => "2025-01-23T15:30:45Z"
  }
)
```

**Final wizard_step_metadata**:
```json
{
  "imported_count": 0,
  "skipped_count": 0,
  "failed_count": 1,
  "import_source": "custom_html",
  "errors": [
    {"item_id": 999, "title": "Rare Song", "error": "Recording not found"}
  ]
}
```

### Example 4: MusicBrainz Series Import Flow

**Input** (List with series ID, no existing items):
```ruby
Music::Songs::List.new(
  name: "Rolling Stone's 500 Greatest Songs",
  musicbrainz_series_id: "abc123-series-mbid",
  wizard_state: {
    "current_step" => 5,
    "import_source" => "musicbrainz_series"
  }
)
# List has 0 list_items (series import creates them)
```

**Import Process**:
1. Job detects `import_source == "musicbrainz_series"`
2. Calls `DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.call(list: @list)`
3. Service:
   - Fetches series data from MusicBrainz API
   - Imports each recording as a `Music::Song`
   - Creates `ListItem` for each song with position from series

**Service Result**:
```ruby
{
  success: true,
  message: "Imported 50 of 52 songs",
  imported_count: 50,
  total_count: 52,
  results: [
    {song: Music::Song(id: 1), position: 1, recording_id: "...", success: true},
    {song: Music::Song(id: 2), position: 2, recording_id: "...", success: true},
    # ...
    {position: 51, recording_id: "...", success: false, error: "Recording not found"},
    {position: 52, recording_id: "...", success: false, error: "API timeout"}
  ]
}
```

**Output** (List after import):
```ruby
list.list_items.count  # => 50
list.list_items.first
# => ListItem(listable_id: 1, position: 1, listable_type: "Music::Song")
```

**Final wizard_step_metadata**:
```json
{
  "import_source": "musicbrainz_series",
  "imported_count": 50,
  "total_count": 52,
  "failed_count": 2,
  "list_items_created": 50,
  "imported_at": "2025-01-23T15:35:00Z"
}
```

---

## Technical Approach

### File Structure

```
web-app/
├── app/
│   ├── sidekiq/
│   │   └── music/
│   │       └── songs/
│   │           └── wizard_import_songs_job.rb           # NEW
│   ├── controllers/
│   │   └── admin/
│   │       └── music/
│   │           └── songs/
│   │               └── list_wizard_controller.rb        # MODIFY: Add import step logic
│   └── components/
│       └── admin/
│           └── music/
│               └── songs/
│                   └── wizard/
│                       ├── import_step_component.rb     # MODIFY: Full implementation
│                       └── import_step_component.html.erb # MODIFY: Full UI
└── test/
    ├── sidekiq/
    │   └── music/
    │       └── songs/
    │           └── wizard_import_songs_job_test.rb      # NEW
    ├── controllers/
    │   └── admin/
    │       └── music/
    │           └── songs/
    │               └── list_wizard_controller_test.rb   # MODIFY: Add import tests
    └── components/
        └── admin/
            └── music/
                └── songs/
                    └── wizard/
                        └── import_step_component_test.rb # NEW
```

---

## Key Implementation Files

### 1. Background Job (NEW)

**File**: `app/sidekiq/music/songs/wizard_import_songs_job.rb`

**Reference Pattern**: `wizard_enrich_list_items_job.rb`

**Implementation** (reference only, ~80 lines):

```ruby
# reference only
class Music::Songs::WizardImportSongsJob
  include Sidekiq::Job

  PROGRESS_UPDATE_INTERVAL = 10

  def perform(list_id)
    @list = Music::Songs::List.find(list_id)
    import_source = @list.wizard_state&.[]("import_source")

    if import_source == "musicbrainz_series"
      import_from_series
    else
      import_from_custom_html
    end
  rescue => e
    handle_error(e.message)
    raise
  end

  private

  # === MusicBrainz Series Path ===
  def import_from_series
    @list.update_wizard_step_status(step: "import", status: "running", progress: 0)

    result = DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.call(list: @list)

    if result[:success]
      @list.update_wizard_step_status(
        step: "import", status: "completed", progress: 100,
        metadata: {
          import_source: "musicbrainz_series",
          imported_count: result[:imported_count],
          total_count: result[:total_count],
          list_items_created: result[:imported_count],
          imported_at: Time.current.iso8601
        }
      )
    else
      handle_error(result[:message])
    end
  end

  # === Custom HTML Path ===
  def import_from_custom_html
    @items_to_import = items_needing_import
    @total = @items_to_import.count

    if @total.zero?
      complete_with_no_items
      return
    end

    @list.update_wizard_step_status(step: "import", status: "running", progress: 0)
    @stats = {imported: 0, skipped: 0, failed: 0, errors: []}

    @items_to_import.each_with_index do |item, index|
      import_item(item)
      update_progress(index + 1) if should_update_progress?(index)
    end

    complete_job
  end

  def items_needing_import
    @list.list_items
      .where(listable_id: nil)
      .where("metadata->>'mb_recording_id' IS NOT NULL")
      .ordered
  end

  def import_item(item)
    mb_id = item.metadata["mb_recording_id"]
    result = DataImporters::Music::Song::Importer.call(musicbrainz_recording_id: mb_id)

    if result.success? && result.item&.persisted?
      item.update!(listable: result.item, verified: true,
        metadata: item.metadata.merge("imported_at" => Time.current.iso8601))
      @stats[:imported] += 1
    else
      error_msg = result.all_errors.join(", ").presence || "Import failed"
      item.update!(metadata: item.metadata.merge("import_error" => error_msg))
      @stats[:failed] += 1
      @stats[:errors] << {item_id: item.id, title: item.metadata["title"], error: error_msg}
    end
  end
end
```

### 2. Import Step Component (MODIFY)

**File**: `app/components/admin/music/songs/wizard/import_step_component.rb`

**Current State**: Minimal stub

**Required Changes**: Add full implementation supporting both import paths

**Implementation** (reference only, ~60 lines):

```ruby
# reference only
class Admin::Music::Songs::Wizard::ImportStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
    # Only load item data for custom_html path
    if custom_html_path?
      @all_items = list.list_items.ordered
      @linked_items = @all_items.where.not(listable_id: nil)
      @items_to_import = @all_items.where(listable_id: nil)
        .where("metadata->>'mb_recording_id' IS NOT NULL")
      @items_without_match = @all_items.where(listable_id: nil)
        .where("metadata->>'mb_recording_id' IS NULL")
    end
  end

  private

  attr_reader :list, :all_items, :linked_items, :items_to_import, :items_without_match

  # Import source detection
  def import_source = list.wizard_state&.[]("import_source") || "custom_html"
  def custom_html_path? = import_source == "custom_html"
  def series_path? = import_source == "musicbrainz_series"
  def musicbrainz_series_id = list.musicbrainz_series_id

  # Step status helpers
  def import_status = list.wizard_step_status("import")
  def import_progress = list.wizard_step_progress("import")
  def import_error = list.wizard_step_error("import")
  def job_metadata = list.wizard_step_metadata("import")

  # Result accessors
  def imported_count = job_metadata["imported_count"] || 0
  def failed_count = job_metadata["failed_count"] || 0
  def total_count = job_metadata["total_count"] || 0
  def list_items_created = job_metadata["list_items_created"] || 0
  def errors = job_metadata["errors"] || []

  # State helpers
  def idle_or_failed? = %w[idle failed].include?(import_status)
  def running? = import_status == "running"
  def completed? = import_status == "completed"
  def failed? = import_status == "failed"

  # Can start import?
  def can_start_import?
    if series_path?
      musicbrainz_series_id.present?
    else
      items_to_import&.any?
    end
  end
end
```

### 3. Controller Modifications (MODIFY)

**File**: `app/controllers/admin/music/songs/list_wizard_controller.rb`

**Changes**:

1. Add `advance_from_import_step` method (similar to `advance_from_validate_step`)
2. Update `advance_step` to call `advance_from_import_step` when step is "import"
3. Implement `load_import_step_data`
4. Implement `enqueue_import_job`

---

## Testing Strategy

### Job Tests

**File**: `test/sidekiq/music/songs/wizard_import_songs_job_test.rb` (NEW)

**Test Cases - Common**:
```ruby
test "job updates wizard_step_status to running at start"
test "job raises error when list not found"
test "job dispatches based on import_source in wizard_state"
```

**Test Cases - Custom HTML Path**:
```ruby
test "custom_html: processes only items with mb_recording_id and no listable_id"
test "custom_html: calls DataImporters::Music::Song::Importer for each item"
test "custom_html: sets listable_id on successful import"
test "custom_html: sets verified to true on successful import"
test "custom_html: stores import timestamp in metadata"
test "custom_html: stores import error on failure"
test "custom_html: continues after individual item failure"
test "custom_html: updates progress periodically"
test "custom_html: updates wizard_step_status to completed with stats"
test "custom_html: handles empty list gracefully"
test "custom_html: skips items where song already exists"
```

**Test Cases - MusicBrainz Series Path**:
```ruby
test "series: calls ImportSongsFromMusicbrainzSeries service"
test "series: stores service result in wizard_step_metadata"
test "series: handles service failure gracefully"
test "series: updates wizard_step_status to completed with stats"
test "series: includes list_items_created in metadata"
```

### Component Tests

**File**: `test/components/admin/music/songs/wizard/import_step_component_test.rb` (NEW)

**Test Cases - Common**:
```ruby
test "renders based on import_source in wizard_state"
test "renders progress bar when job running"
test "uses wizard-step controller when job is running"
test "does not use wizard-step controller when job is idle"
test "renders error message when job failed"
```

**Test Cases - Custom HTML Path**:
```ruby
test "custom_html: renders stats cards with correct counts"
test "custom_html: renders Start Import button when job idle"
test "custom_html: disables Start Import button when no items to import"
test "custom_html: displays results summary when completed"
test "custom_html: shows failed items section when failures exist"
test "custom_html: shows items to import preview table"
test "custom_html: correctly categorizes linked vs unlinked items"
```

**Test Cases - MusicBrainz Series Path**:
```ruby
test "series: renders series info card with musicbrainz_series_id"
test "series: renders Import from Series button when job idle"
test "series: displays series import results when completed"
test "series: shows songs imported and list items created counts"
```

### Controller Tests

**File**: `test/controllers/admin/music/songs/list_wizard_controller_test.rb` (MODIFY)

**Add Test Cases**:
```ruby
test "import step loads item categories correctly"
test "advancing from import step enqueues job when idle"
test "advancing from import step proceeds when job completed"
test "advancing from import step blocks when job running"
test "import step handles zero items to import"
```

---

## Implementation Steps

### Phase 1: Background Job (Estimated: 1.5 hours)

1. **Generate job file**
   - [ ] `bin/rails generate sidekiq:job music/songs/wizard_import_songs`
   - [ ] Implement `perform(list_id)` method
   - [ ] Add progress tracking with `PROGRESS_UPDATE_INTERVAL`
   - [ ] Implement `import_item` method calling `DataImporters::Music::Song::Importer`
   - [ ] Add error handling per item

2. **Write job tests**
   - [ ] Test successful import flow
   - [ ] Test error handling
   - [ ] Test empty list handling
   - [ ] Test idempotency
   - [ ] Test progress updates
   - [ ] Run tests

### Phase 2: View Component (Estimated: 1.5 hours)

3. **Update import step component Ruby class**
   - [ ] Add helper methods following enrich_step_component pattern
   - [ ] Add item categorization methods
   - [ ] Add step-specific status accessors

4. **Update import step component template**
   - [ ] Add full UI with all 4 states
   - [ ] Add conditional Stimulus controller attachment
   - [ ] Add stats cards
   - [ ] Add items to import preview
   - [ ] Add results display with failed items section

5. **Write component tests**
   - [ ] Test all UI states
   - [ ] Test Stimulus controller attachment
   - [ ] Test item categorization display
   - [ ] Run tests

### Phase 3: Controller Integration (Estimated: 1 hour)

6. **Update controller**
   - [ ] Implement `load_import_step_data`
   - [ ] Implement `enqueue_import_job`
   - [ ] Add `advance_from_import_step` method
   - [ ] Update `advance_step` case statement

7. **Write controller tests**
   - [ ] Test data loading
   - [ ] Test job enqueue
   - [ ] Test step advancement
   - [ ] Run tests

### Phase 4: Integration Testing (Estimated: 30 minutes)

8. **Manual browser testing**
   - [ ] Navigate through wizard to import step
   - [ ] Click "Start Import"
   - [ ] Verify progress updates
   - [ ] Verify results display
   - [ ] Test with items that already have songs (finder match)
   - [ ] Test error cases

9. **Full test suite**
   - [ ] Run all wizard tests
   - [ ] Verify 0 failures
   - [ ] Fix any integration issues

---

## Validation Checklist (Definition of Done)

- [ ] Background job exists and tested (15+ tests passing)
- [ ] Job imports songs using `DataImporters::Music::Song::Importer`
- [ ] Job links imported songs to list_items correctly
- [ ] Job sets `verified = true` on imported items
- [ ] Job handles errors gracefully per item
- [ ] View component renders all UI states
- [ ] Component tests pass (12+ tests)
- [ ] Controller handles import step correctly
- [ ] Controller tests pass (5+ new tests)
- [ ] Progress updates work during import
- [ ] Stats display correctly after completion
- [ ] Error messages display correctly
- [ ] Navigation flow works end-to-end
- [ ] All tests pass (32+ new tests total)
- [ ] No N+1 queries introduced
- [ ] Documentation updated

---

## Dependencies

### Depends On (Completed)
- [086] Infrastructure - wizard_state, routes, model helpers
- [087] Wizard UI Shell - WizardController, polling Stimulus controller
- [088] Step 0: Import Source - import_source selection
- [089] Step 1: Parse - Creates list_items with metadata
- [090] Step 2: Enrich - Adds `mb_recording_id` to metadata
- [091] Step 3: Validation - Sets `verified` flag
- [092] Step 4: Review UI - Displays items for review
- [093] Step 4: Actions - Manual linking and MusicBrainz search

### Needed By (Blocked Until This Completes)
- [095] Polish & Integration - Final wizard polish

### External References
- **Song Importer**: `app/lib/data_importers/music/song/importer.rb`
- **Import Query**: `app/lib/data_importers/music/song/import_query.rb`
- **Finder**: `app/lib/data_importers/music/song/finder.rb`
- **Series Importer**: `app/lib/data_importers/music/lists/import_songs_from_musicbrainz_series.rb`
- **Existing Series Job**: `app/sidekiq/music/import_song_list_from_musicbrainz_series_job.rb`
- **Enrich Job Pattern**: `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb`
- **Enrich Component Pattern**: `app/components/admin/music/songs/wizard/enrich_step_component.rb`
- **Source Step Component**: `app/components/admin/music/songs/wizard/source_step_component.rb`
- **Items JSON Importer Reference**: `app/lib/services/lists/music/songs/items_json_importer.rb`
- **ListItem Model**: `app/models/list_item.rb`
- **List Model**: `app/models/list.rb` (wizard_step_status methods)

---

## Related Tasks

- **Previous**: [093] Song Step 4: Actions
- **Next**: [095] Polish & Integration
- **Reference**: Existing song importer and series import patterns

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns (Sidekiq jobs, ViewComponents, polling)
- Do not duplicate authoritative code; **link to files by path**
- Respect snippet budget (<=40 lines per snippet)
- Use `DataImporters::Music::Song::Importer` - do NOT create new importer
- Update wizard_step_status atomically at all stages
- Make job idempotent (can retry safely)
- Use step-namespaced status pattern from 090a

### Required Outputs
- New file: `app/sidekiq/music/songs/wizard_import_songs_job.rb`
- New file: `test/sidekiq/music/songs/wizard_import_songs_job_test.rb`
- New file: `test/components/admin/music/songs/wizard/import_step_component_test.rb`
- Modified: `app/components/admin/music/songs/wizard/import_step_component.rb`
- Modified: `app/components/admin/music/songs/wizard/import_step_component.html.erb`
- Modified: `app/controllers/admin/music/songs/list_wizard_controller.rb`
- Modified: `test/controllers/admin/music/songs/list_wizard_controller_test.rb`
- Passing tests for all new functionality (32+ tests)
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1. **codebase-pattern-finder** -> Already done (collected wizard job patterns, enrich component patterns)
2. **codebase-analyzer** -> Already done (understood DataImporters::Music::Song::Importer interface)
3. **technical-writer** -> Update docs after implementation

### Test Fixtures
- Use existing `lists(:music_songs_list)` fixture
- Create list_items with varied states programmatically in tests
- Mock `DataImporters::Music::Song::Importer` responses in tests

---

## Implementation Notes

### Files Created
- `app/sidekiq/music/songs/wizard_import_songs_job.rb` - Background job handling both custom HTML and series import paths
- `test/sidekiq/music/songs/wizard_import_songs_job_test.rb` - 21 tests covering both paths
- `test/components/admin/music/songs/wizard/import_step_component_test.rb` - 22 tests for component

### Files Modified
- `app/components/admin/music/songs/wizard/import_step_component.rb` - Full implementation with helper methods
- `app/components/admin/music/songs/wizard/import_step_component.html.erb` - Complete UI for both paths and all states
- `app/components/admin/music/songs/wizard/complete_step_component.html.erb` - Fixed route helpers and Turbo Frame navigation
- `app/controllers/admin/music/songs/list_wizard_controller.rb` - Added import step logic
- `test/controllers/admin/music/songs/list_wizard_controller_test.rb` - Added 7 import step tests

### Key Implementation Details
- Job dispatches based on `import_source` in wizard_state
- Custom HTML path: Uses `DataImporters::Music::Song::Importer` for individual items
- Series path: Delegates to `DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries`
- Progress updates every 10 items or 5 seconds for custom HTML path
- Sets `verified = true` and stores `imported_at` timestamp on successful import
- Series path marks all imported items as verified after completion
- Stores `import_error` and `import_attempted_at` on failed imports
- Component renders different UI for series vs custom_html paths
- Stimulus controller attached only when job is running
- Idempotent: skips items with `listable_id` OR `imported_at` in metadata
- Complete Wizard button uses `turbo_frame: "_top"` for full page navigation

### Test Coverage
- Job tests: 21 tests (Custom HTML: 14, Series: 6, Common: 1)
- Component tests: 22 tests (Custom HTML: 8, Series: 5, Common: 9)
- Controller tests: 7 new tests for import step
- Total new tests: 50 tests, all passing
- All 195 wizard-related tests pass

---

## Deviations from Plan

- Added `imported_at` check to `items_needing_import` query for additional idempotency
- Added `mark_series_items_as_verified` method to mark series-imported items as verified
- Fixed complete step component route helpers (`admin_songs_list_path` instead of `admin_list_path`)
- Added `turbo_frame: "_top"` to Complete Wizard button for proper page navigation

---

## Documentation Updated

- [x] This task file updated with implementation notes
- [x] `todo.md` updated
- [x] Related class documentation updated (`docs/sidekiq/music/songs/wizard_import_songs_job.md`)

---

## Notes

### Design Rationale

**Why Support Both Paths in One Job?**
- Unified progress tracking and error handling
- Single controller flow regardless of import source
- Simpler component logic - just check `import_source`
- Reuses existing, well-tested `ImportSongsFromMusicbrainzSeries` service

**Why Reuse Existing Series Importer?**
- `DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries` is already production-ready
- Handles all the complexity: API calls, song imports, list_item creation
- No need to duplicate that logic in the wizard job
- Just wrap it with wizard progress tracking

**Why Skip Already-Linked Items (Custom HTML)?**
- Items with `listable_id` were matched during enrichment (OpenSearch) or manually linked
- Re-importing would be wasteful - the song already exists
- The importer's finder would return the same song anyway
- Keeps import step focused on truly new imports

**Why Set verified = true (Custom HTML)?**
- User has explicitly chosen to import these items
- MusicBrainz recording ID is an authoritative identifier
- No ambiguity about the match (unlike fuzzy OpenSearch matches)
- Consistent with `link_musicbrainz` action behavior

**Why Series Path Skips Intermediate Steps?**
- All data comes from MusicBrainz series API (no HTML parsing needed)
- No enrichment needed - series provides the recording IDs
- No validation needed - MusicBrainz is authoritative
- No review needed - user chose the series explicitly

### Performance Considerations
- MusicBrainz API rate limiting: 1 request/second
- Custom HTML path: Batch progress updates (every 10 items) reduce DB writes
- Series path: Service handles its own API calls internally
- Consider bulk insert for list_item updates in future optimization

### Security Considerations
- Job runs in background worker (no direct user input in job)
- List ID validated by ActiveRecord (raises if not found)
- wizard_state updates use ActiveRecord (prevents SQL injection)
- MusicBrainz IDs validated by ImportQuery (UUID format check)
- Series ID validated by the series importer service

### Future Enhancements (Out of Scope)
- [ ] Retry individual failed imports from UI
- [ ] Parallel imports (currently sequential for rate limiting)
- [ ] Bulk import progress with streaming updates
- [ ] Cancel running import job
- [ ] Series import with progress updates (currently just start/complete)

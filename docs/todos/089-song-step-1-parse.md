# [089] - Song Wizard: Step 1 - Parse HTML

## Status
- **Status**: Planned
- **Priority**: High
- **Created**: 2025-01-19
- **Updated**: 2025-01-23
- **Part**: 4 of 10

## Overview
Implement Step 1 of the song list wizard where raw HTML is parsed using AI into unverified `list_items` with structured metadata. This step reuses the existing `Services::Ai::Tasks::Lists::Music::SongsRawParserTask` but creates `list_items` records instead of populating `items_json`. Users see real-time progress updates via polling as the background job processes the HTML.

## Context

This is **Part 4 of 10** in the Song List Wizard implementation:

1. [086] Infrastructure ✅ Complete
2. [087] Wizard UI Shell ✅ Complete
3. [088] Step 0: Import Source Choice ✅ Complete
4. **[089] Step 1: Parse HTML** ← You are here
5. [090] Step 2: Enrich
6. [091] Step 3: Validation
7. [092] Step 4: Review UI
8. [093] Step 4: Actions
9. [094] Step 5: Import
10. [095] Polish & Integration

### The Flow

**Custom HTML Path Only** (MusicBrainz path skips this step):
```
Step 0 (source) → Step 1 (parse) → Step 2 (enrich) → ...
```

**Only applies when**: `wizard_state["import_source"] == "custom_html"`

### What This Builds

This task implements:
- Parse step view component with HTML preview and progress tracking UI
- Background job (`Music::Songs::WizardParseListJob`) that:
  - Calls existing AI parser service
  - Creates unverified `list_items` from parsed data
  - Updates wizard_state with job progress
- Progress tracking via Stimulus polling controller (already exists from [087])
- Controller logic to enqueue parse job and advance to next step

This task does NOT implement:
- AI parsing logic (already exists at `Services::Ai::Tasks::Lists::Music::SongsRawParserTask`)
- Enrichment logic (covered in [090])
- Verification/validation logic (covered in [091])

### Key Design Decisions

**Job vs Service Pattern**:
- **Job**: `Music::Songs::WizardParseListJob` - Sidekiq job for async execution
- **Service**: Existing `Services::Ai::Tasks::Lists::Music::SongsRawParserTask` - called by job
- **Why**: Separate orchestration (job) from business logic (service) for testability

**Progress Tracking Approach**:
- Use `list.update_wizard_job_status(status:, progress:, metadata:)` helper (from [086])
- Polling frequency: 2 seconds (defined in `wizard_step_controller.js`)
- Progress updates: Start (0%), Complete (100%), Failure (error message)
- No intermediate progress (AI call is atomic, no streaming)

**Data Storage**:
- Create `list_items` records with `verified: false`
- Store parsed data in `list_items.metadata` JSONB column
- Leave `listable_id` NULL (will be populated during enrichment in [090])
- Use `position` field from parsed `rank` value

---

## Requirements

### Functional Requirements

#### FR-1: Parse Step View Component
**Contract**: Display HTML preview, job status, progress bar, and navigation controls

**UI Components**:
- HTML preview (truncated, read-only)
- "Start Parsing" button (enabled when job idle)
- Progress bar (shows 0-100%, updated via polling)
- Status text (e.g., "Parsing HTML...", "Complete", "Error: ...")
- Error display area (shown if job fails)
- Next button (disabled until job completes successfully)

**Stimulus Controller Integration**:
- Uses `wizard_step_controller.js` (already implemented in [087])
- Targets: `progressBar`, `statusText`, `nextButton`
- Automatically starts polling on page load if job is running
- Stops polling when job completes or fails

**Implementation**: `app/components/admin/music/songs/wizard/parse_step_component.html.erb`

#### FR-2: Background Job for Parsing
**Contract**: Parse raw HTML into list_items asynchronously with progress tracking

**Job Specification**:
- **File**: `app/sidekiq/music/songs/wizard_parse_list_job.rb`
- **Queue**: `default` (standard Sidekiq queue)
- **Parameters**: `list_id` (integer)

**Job Workflow**:
1. Find list by ID
2. Update wizard_state: `{job_status: "running", job_progress: 0}`
3. Call `Services::Ai::Tasks::Lists::Music::SongsRawParserTask.new(parent: list).call`
4. Extract parsed songs from result
5. Create `list_items` for each parsed song
6. Update wizard_state: `{job_status: "completed", job_progress: 100, job_metadata: {total_items: N}}`
7. Handle errors and update wizard_state accordingly

**Error Handling**:
- AI service failures: Log error, update wizard_state with error message
- Database errors: Log error, update wizard_state with error message
- Missing raw_html: Fail immediately with clear error message

**Implementation**: Reference pattern from `Music::Songs::ImportListItemsFromJsonJob` (lines 1-21)

#### FR-3: List Item Creation from Parsed Data
**Contract**: Transform AI parser output into ListItem records with proper metadata structure

**Input Schema** (from AI parser):
```json
{
  "songs": [
    {
      "rank": 1,
      "title": "Bohemian Rhapsody",
      "artists": ["Queen"],
      "album": "A Night at the Opera",
      "release_year": 1975
    }
  ]
}
```

**Output Schema** (ListItem record):
```ruby
ListItem.create!(
  list_id: list.id,
  listable_type: "Music::Song",
  listable_id: nil,  # Populated during enrichment
  verified: false,
  position: 1,  # From parsed rank, or sequential index if rank is null
  metadata: {
    "rank" => 1,
    "title" => "Bohemian Rhapsody",
    "artists" => ["Queen"],
    "album" => "A Night at the Opera",
    "release_year" => 1975
  }
)
```

**Field Mapping Rules**:
- `rank` → `position` (use index + 1 if rank is null)
- `title`, `artists`, `album`, `release_year` → stored in `metadata`
- `listable_type` → always `"Music::Song"`
- `listable_id` → always `nil` (enrichment populates this)
- `verified` → always `false`

**Validation**:
- Must have `list_id`
- Must have `listable_type`
- Position must be > 0
- Metadata must be valid JSON

#### FR-4: Controller Action to Start Parsing
**Contract**: Enqueue background job and redirect to parse step for polling

**Action**: `advance_step` from "source" step (already implemented in [088])

**New Requirement**: Override behavior when advancing FROM "parse" step
- Current behavior: Increments step by 1
- New behavior: Check if job is complete before allowing advance

**Implementation Location**: `app/controllers/admin/music/songs/list_wizard_controller.rb`

**Logic**:
```ruby
# When user clicks "Next" on parse step
def advance_step
  if params[:step] == "source"
    # Existing logic from [088]
    advance_from_source_step
  elsif params[:step] == "parse"
    # New logic for this task
    if wizard_entity.wizard_job_status != "completed"
      redirect_to action: :show_step, step: "parse", alert: "Parsing must complete before proceeding"
      return
    end
    # Continue to next step
    super
  else
    super
  end
end
```

#### FR-5: Parse Step Data Loading
**Contract**: Load HTML preview data when rendering parse step

**Method**: `load_parse_step_data` (called by `show_step` action)

**Data to Load**:
```ruby
def load_parse_step_data
  @raw_html_preview = @list.raw_html&.truncate(500)
  @parsed_count = @list.list_items.unverified.count
end
```

**Usage**: Available in parse step component view

---

### Non-Functional Requirements

#### NFR-1: Performance
- [ ] AI parsing completes in < 60 seconds for lists with < 100 items
- [ ] AI parsing completes in < 120 seconds for lists with 100-500 items
- [ ] ListItem creation uses `insert_all` for bulk inserts (> 50 items)
- [ ] No N+1 queries during list_item creation
- [ ] Polling adds < 10ms overhead per request

#### NFR-2: Data Integrity
- [ ] Job is idempotent (can be safely retried)
- [ ] Existing unverified list_items are deleted before creating new ones
- [ ] wizard_state updates are atomic (single database transaction)
- [ ] Failed jobs do not leave partial data (use transaction)

#### NFR-3: Error Handling
- [ ] AI service timeouts handled gracefully
- [ ] Network errors logged and surfaced to user
- [ ] Invalid HTML shows clear error message
- [ ] Empty parse results show warning (not error)
- [ ] Database constraint violations logged and handled

#### NFR-4: Observability
- [ ] Job start/completion logged with metadata
- [ ] AI service calls logged with duration
- [ ] Errors include full stack trace in logs
- [ ] Success metrics include item count and duration

---

## Contracts & Schemas

### ListItem Metadata Schema

**JSON Schema** (stored in `list_items.metadata` JSONB column):

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["title", "artists"],
  "properties": {
    "rank": {
      "type": ["integer", "null"],
      "description": "Original rank from parsed HTML (may be null)"
    },
    "title": {
      "type": "string",
      "description": "Song title as extracted from HTML",
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
      "description": "Album name if present in HTML"
    },
    "release_year": {
      "type": ["integer", "null"],
      "description": "Release year if present in HTML",
      "minimum": 1900,
      "maximum": 2100
    }
  }
}
```

### Endpoint Table

| Verb | Path | Purpose | Params/Body | Auth | Response |
|------|------|---------|-------------|------|----------|
| GET | `/wizard/step/parse` | Show parse step | - | admin | HTML (Turbo Frame) |
| POST | `/wizard/step/parse/advance` | Start parsing job | step="parse" | admin | 302 redirect to parse step |
| GET | `/wizard/step/parse/status` | Get job status | - | admin | JSON (status endpoint schema) |

### Status Endpoint Response

**Endpoint**: `GET /admin/songs/lists/:list_id/wizard/step/parse/status`

**Response** (success):
```json
{
  "status": "completed",
  "progress": 100,
  "error": null,
  "metadata": {
    "total_items": 50
  }
}
```

**Response** (running):
```json
{
  "status": "running",
  "progress": 0,
  "error": null,
  "metadata": {}
}
```

**Response** (failed):
```json
{
  "status": "failed",
  "progress": 0,
  "error": "AI service timeout after 60 seconds",
  "metadata": {}
}
```

### Wizard State Update

**Before** (after source step):
```json
{
  "current_step": 1,
  "import_source": "custom_html",
  "job_status": "idle",
  "job_progress": 0,
  "job_error": null,
  "job_metadata": {}
}
```

**During parsing**:
```json
{
  "current_step": 1,
  "import_source": "custom_html",
  "job_status": "running",
  "job_progress": 0,
  "job_error": null,
  "job_metadata": {}
}
```

**After successful parsing**:
```json
{
  "current_step": 1,
  "import_source": "custom_html",
  "job_status": "completed",
  "job_progress": 100,
  "job_error": null,
  "job_metadata": {
    "total_items": 50,
    "parsed_at": "2025-01-23T15:30:00Z"
  }
}
```

**After failed parsing**:
```json
{
  "current_step": 1,
  "import_source": "custom_html",
  "job_status": "failed",
  "job_progress": 0,
  "job_error": "Raw HTML is blank or missing",
  "job_metadata": {}
}
```

---

## Acceptance Criteria

### View Component
- [ ] `Admin::Music::Songs::Wizard::ParseStepComponent` renders all UI elements
- [ ] HTML preview shows truncated raw_html (max 500 chars)
- [ ] "Start Parsing" button exists and triggers job enqueue
- [ ] Progress bar exists with `data-wizard-step-target="progressBar"` attribute
- [ ] Status text exists with `data-wizard-step-target="statusText"` attribute
- [ ] Next button exists with `data-wizard-step-target="nextButton"` attribute
- [ ] Error display area exists and hidden by default
- [ ] Uses Stimulus controller `wizard_step_controller`

### Background Job
- [ ] `Music::Songs::WizardParseListJob` exists in correct namespace
- [ ] Job updates wizard_state to "running" at start
- [ ] Job calls `SongsRawParserTask` correctly
- [ ] Job creates ListItem records for each parsed song
- [ ] Job updates wizard_state to "completed" on success
- [ ] Job updates wizard_state to "failed" on error
- [ ] Job logs all important events (start, success, failure)
- [ ] Job is idempotent (clears old unverified items first)

### ListItem Creation
- [ ] Each parsed song creates one ListItem record
- [ ] `verified` is always `false`
- [ ] `listable_type` is always `"Music::Song"`
- [ ] `listable_id` is always `nil`
- [ ] `position` uses rank if present, otherwise sequential index
- [ ] `metadata` contains all parsed fields (rank, title, artists, album, release_year)
- [ ] Metadata structure matches JSON schema exactly
- [ ] Bulk insert used for > 50 items (performance)

### Controller Logic
- [ ] `load_parse_step_data` loads HTML preview and parsed count
- [ ] Advancing from parse step validates job status
- [ ] Cannot advance if job not completed
- [ ] Can advance to enrich step when job completed
- [ ] Flash alert shown if trying to advance prematurely

### Progress Tracking
- [ ] Polling starts automatically when step loads
- [ ] Progress bar updates when job status changes
- [ ] Status text shows "Parsing HTML..." when running
- [ ] Status text shows "Complete! Parsed X items" when done
- [ ] Error message displayed if job fails
- [ ] Next button enabled when job completes
- [ ] Next button disabled while job running

### Error Handling
- [ ] Missing raw_html fails with clear error
- [ ] AI service timeout handled gracefully
- [ ] Network errors show user-friendly message
- [ ] Empty parse results (0 songs) handled gracefully
- [ ] Duplicate position values handled (use sequential fallback)

---

## Golden Examples

### Example 1: Successful Parse Flow

**Input** (list.raw_html):
```html
<ol>
  <li>Bohemian Rhapsody - Queen (A Night at the Opera, 1975)</li>
  <li>Imagine - John Lennon (Imagine, 1971)</li>
  <li>Smells Like Teen Spirit - Nirvana</li>
</ol>
```

**AI Parser Output** (`SongsRawParserTask` result):
```ruby
{
  success: true,
  data: {
    songs: [
      {rank: 1, title: "Bohemian Rhapsody", artists: ["Queen"], album: "A Night at the Opera", release_year: 1975},
      {rank: 2, title: "Imagine", artists: ["John Lennon"], album: "Imagine", release_year: 1971},
      {rank: 3, title: "Smells Like Teen Spirit", artists: ["Nirvana"], album: nil, release_year: nil}
    ]
  }
}
```

**Created ListItems**:
```ruby
# ListItem 1
{
  list_id: 123,
  listable_type: "Music::Song",
  listable_id: nil,
  verified: false,
  position: 1,
  metadata: {
    rank: 1,
    title: "Bohemian Rhapsody",
    artists: ["Queen"],
    album: "A Night at the Opera",
    release_year: 1975
  }
}

# ListItem 2
{
  list_id: 123,
  listable_type: "Music::Song",
  listable_id: nil,
  verified: false,
  position: 2,
  metadata: {
    rank: 2,
    title: "Imagine",
    artists: ["John Lennon"],
    album: "Imagine",
    release_year: 1971
  }
}

# ListItem 3
{
  list_id: 123,
  listable_type: "Music::Song",
  listable_id: nil,
  verified: false,
  position: 3,
  metadata: {
    rank: 3,
    title: "Smells Like Teen Spirit",
    artists: ["Nirvana"],
    album: nil,
    release_year: nil
  }
}
```

**Final wizard_state**:
```json
{
  "current_step": 1,
  "job_status": "completed",
  "job_progress": 100,
  "job_metadata": {
    "total_items": 3,
    "parsed_at": "2025-01-23T15:30:45Z"
  }
}
```

### Example 2: Error Handling - Missing raw_html

**Input**: `list.raw_html` is `nil`

**Job Behavior**:
1. Job starts
2. Detects missing raw_html immediately
3. Updates wizard_state with error
4. Raises exception (Sidekiq retries)

**Final wizard_state**:
```json
{
  "current_step": 1,
  "job_status": "failed",
  "job_progress": 0,
  "job_error": "Cannot parse: raw_html is blank. Please go back and provide HTML content.",
  "job_metadata": {}
}
```

**UI Display**:
- Progress bar: 0%
- Status text: "Error"
- Error message: "Cannot parse: raw_html is blank. Please go back and provide HTML content."
- Next button: Disabled
- "Start Parsing" button: Enabled (can retry)

### Example 3: Edge Case - Null Ranks

**Input** (AI parser returns null ranks):
```ruby
{
  songs: [
    {rank: nil, title: "Song A", artists: ["Artist 1"], album: nil, release_year: nil},
    {rank: nil, title: "Song B", artists: ["Artist 2"], album: nil, release_year: nil}
  ]
}
```

**Created ListItems** (positions assigned sequentially):
```ruby
# ListItem 1
{
  position: 1,  # Index 0 + 1
  metadata: {rank: nil, title: "Song A", artists: ["Artist 1"], album: nil, release_year: nil}
}

# ListItem 2
{
  position: 2,  # Index 1 + 1
  metadata: {rank: nil, title: "Song B", artists: ["Artist 2"], album: nil, release_year: nil}
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
│   │           └── wizard_parse_list_job.rb           # NEW: Background job
│   ├── controllers/
│   │   └── admin/
│   │       └── music/
│   │           └── songs/
│   │               └── list_wizard_controller.rb       # MODIFY: Add parse data loading
│   ├── components/
│   │   └── admin/
│   │       └── music/
│   │           └── songs/
│   │               └── wizard/
│   │                   ├── parse_step_component.rb     # MODIFY: Add logic
│   │                   └── parse_step_component.html.erb # MODIFY: Add UI
│   └── lib/
│       └── services/
│           └── ai/
│               └── tasks/
│                   └── lists/
│                       └── music/
│                           └── songs_raw_parser_task.rb # EXISTS: No changes
└── test/
    ├── sidekiq/
    │   └── music/
    │       └── songs/
    │           └── wizard_parse_list_job_test.rb       # NEW: Job tests
    ├── controllers/
    │   └── admin/
    │       └── music/
    │           └── songs/
    │               └── list_wizard_controller_test.rb   # MODIFY: Add parse step tests
    └── components/
        └── admin/
            └── music/
                └── songs/
                    └── wizard/
                        └── parse_step_component_test.rb # MODIFY: Add parse UI tests
```

---

## Key Implementation Files

### 1. Background Job

**File**: `app/sidekiq/music/songs/wizard_parse_list_job.rb` (NEW)

**Pattern Reference**: `Music::Songs::ImportListItemsFromJsonJob` (lines 1-21)

**Implementation** (reference only, ≤40 lines):

```ruby
class Music::Songs::WizardParseListJob
  include Sidekiq::Job

  def perform(list_id)
    list = Music::Songs::List.find(list_id)

    # Validate preconditions
    if list.raw_html.blank?
      handle_error(list, "Cannot parse: raw_html is blank. Please go back and provide HTML content.")
      return
    end

    # Update status to running
    list.update_wizard_job_status(status: "running", progress: 0)

    # Clear existing unverified items (idempotency)
    list.list_items.unverified.destroy_all

    # Call AI parser
    result = Services::Ai::Tasks::Lists::Music::SongsRawParserTask.new(parent: list).call

    unless result.success
      handle_error(list, result.message || "Parsing failed")
      return
    end

    # Create list_items from parsed data
    songs = result.data[:songs]
    list_items_attrs = songs.map.with_index do |song, index|
      {
        list_id: list.id,
        listable_type: "Music::Song",
        listable_id: nil,
        verified: false,
        position: song[:rank] || (index + 1),
        metadata: song.slice(:rank, :title, :artists, :album, :release_year),
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    ListItem.insert_all(list_items_attrs) if list_items_attrs.any?

    # Update status to completed
    list.update_wizard_job_status(
      status: "completed",
      progress: 100,
      metadata: {total_items: songs.count, parsed_at: Time.current.iso8601}
    )

    Rails.logger.info "WizardParseListJob completed for list #{list_id}: parsed #{songs.count} items"
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "WizardParseListJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WizardParseListJob failed for list #{list_id}: #{e.message}"
    handle_error(list, e.message) if list
    raise
  end

  private

  def handle_error(list, error_message)
    list.update_wizard_job_status(
      status: "failed",
      progress: 0,
      error: error_message
    )
  end
end
```

**Key Points**:
- Uses `insert_all` for bulk insert performance
- Clears existing unverified items for idempotency
- Updates wizard_state at start, success, and failure
- Validates raw_html presence before processing
- Logs all important events

---

### 2. Parse Step Component Template

**File**: `app/components/admin/music/songs/wizard/parse_step_component.html.erb` (MODIFY)

**Current State**: Stub implementation from [087]

**Required Changes**: Add full parse UI with progress tracking

**Implementation** (reference only, ≤40 lines):

```erb
<%= render(Wizard::StepComponent.new(
  title: "Parse HTML",
  description: "Extract song information from HTML",
  step_number: 1,
  active: true
)) do |step| %>
  <% step.with_step_content do %>
    <div data-controller="wizard-step"
         data-wizard-step-list-id-value="<%= list.id %>"
         data-wizard-step-step-name-value="parse">

      <!-- HTML Preview -->
      <div class="card bg-base-200 mb-6">
        <div class="card-body">
          <h3 class="card-title text-sm">HTML Preview</h3>
          <pre class="text-xs overflow-x-auto"><%= @raw_html_preview %></pre>
          <% if list.raw_html.length > 500 %>
            <p class="text-xs text-base-content/70">... (truncated)</p>
          <% end %>
        </div>
      </div>

      <!-- Status & Progress -->
      <div class="mb-6">
        <div class="flex justify-between items-center mb-2">
          <span class="text-sm font-medium" data-wizard-step-target="statusText">
            <%= job_status_text(list) %>
          </span>
          <span class="text-sm text-base-content/70">
            <%= list.wizard_job_progress %>%
          </span>
        </div>
        <progress
          class="progress progress-primary w-full"
          value="<%= list.wizard_job_progress %>"
          max="100"
          data-wizard-step-target="progressBar">
        </progress>
      </div>

      <!-- Error Display -->
      <% if list.wizard_job_error.present? %>
        <div class="alert alert-error mb-6">
          <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>
          <span><%= list.wizard_job_error %></span>
        </div>
      <% end %>

      <!-- Action Buttons -->
      <div class="flex gap-3">
        <% if list.wizard_job_status == "idle" || list.wizard_job_status == "failed" %>
          <%= button_to "Start Parsing",
              advance_step_admin_songs_list_wizard_path(list_id: list.id, step: "parse"),
              method: :post,
              class: "btn btn-primary",
              data: {turbo_frame: "wizard_content"} %>
        <% end %>
      </div>
    </div>
  <% end %>
<% end %>
```

**Helper Method** (add to `list_wizard_helper.rb`):

```ruby
def job_status_text(list)
  case list.wizard_job_status
  when "idle" then "Ready to parse"
  when "running" then "Parsing HTML..."
  when "completed" then "Complete! Parsed #{list.wizard_job_metadata["total_items"] || 0} items"
  when "failed" then "Parsing failed"
  else "Unknown status"
  end
end
```

---

### 3. Controller Modifications

**File**: `app/controllers/admin/music/songs/list_wizard_controller.rb` (MODIFY)

**Location**: Lines 8-14 (advance_step override), add parse case

**Changes**:

```ruby
def advance_step
  current_step_name = params[:step]

  # Source step handling (from [088])
  if current_step_name == "source"
    advance_from_source_step
  # Parse step handling (NEW for this task)
  elsif current_step_name == "parse"
    advance_from_parse_step
  else
    super
  end
end

private

def advance_from_parse_step
  # Enqueue parsing job if not already running/completed
  if wizard_entity.wizard_job_status == "idle" || wizard_entity.wizard_job_status == "failed"
    Music::Songs::WizardParseListJob.perform_async(wizard_entity.id)
    redirect_to action: :show_step, step: "parse", notice: "Parsing started"
  elsif wizard_entity.wizard_job_status == "completed"
    # Advance to enrich step
    super
  else
    # Job is running, stay on parse step
    redirect_to action: :show_step, step: "parse", alert: "Parsing in progress, please wait"
  end
end
```

**Add to `load_step_data` method**:

```ruby
when "parse"
  load_parse_step_data
```

**Add new method**:

```ruby
def load_parse_step_data
  @raw_html_preview = @list.raw_html&.truncate(500) || "(No HTML provided)"
  @parsed_count = @list.list_items.unverified.count
end
```

---

### 4. AI Parser Service (NO CHANGES)

**File**: `app/lib/services/ai/tasks/lists/music/songs_raw_parser_task.rb`

**Status**: ✅ Already implemented correctly

**Interface Used by Job**:
```ruby
result = Services::Ai::Tasks::Lists::Music::SongsRawParserTask.new(parent: list).call

# Returns Result object:
# - result.success => boolean
# - result.data => {songs: [{rank, title, artists, album, release_year}, ...]}
# - result.message => error message if failed
# - result.ai_chat => AiChat record
```

**See**: Lines 1-72 for full implementation

---

## Testing Strategy

### Background Job Tests

**File**: `test/sidekiq/music/songs/wizard_parse_list_job_test.rb` (NEW)

**Test Cases**:

```ruby
require "test_helper"

class Music::Songs::WizardParseListJobTest < ActiveSupport::TestCase
  setup do
    @list = music_songs_lists(:with_raw_html)
    @list.update!(raw_html: "<ol><li>Song 1 - Artist 1</li></ol>")
  end

  test "job updates wizard_state to running at start" do
    # Stub AI service
    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(
      OpenStruct.new(success: true, data: {songs: []})
    )

    Music::Songs::WizardParseListJob.new.perform(@list.id)
    # Check that running status was set (would need to capture state mid-execution)
  end

  test "job creates list_items from parsed songs" do
    parsed_songs = [
      {rank: 1, title: "Song 1", artists: ["Artist 1"], album: nil, release_year: nil},
      {rank: 2, title: "Song 2", artists: ["Artist 2"], album: "Album 2", release_year: 2020}
    ]

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(
      OpenStruct.new(success: true, data: {songs: parsed_songs})
    )

    assert_difference "@list.list_items.unverified.count", 2 do
      Music::Songs::WizardParseListJob.new.perform(@list.id)
    end

    @list.reload
    item1 = @list.list_items.find_by(position: 1)
    assert_equal "Song 1", item1.metadata["title"]
    assert_equal ["Artist 1"], item1.metadata["artists"]
    assert_nil item1.listable_id
    assert_not item1.verified
  end

  test "job updates wizard_state to completed on success" do
    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(
      OpenStruct.new(success: true, data: {songs: [{rank: 1, title: "Test", artists: ["Artist"], album: nil, release_year: nil}]})
    )

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal "completed", @list.wizard_job_status
    assert_equal 100, @list.wizard_job_progress
    assert_equal 1, @list.wizard_job_metadata["total_items"]
  end

  test "job updates wizard_state to failed on error" do
    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(
      OpenStruct.new(success: false, message: "AI service timeout")
    )

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal "failed", @list.wizard_job_status
    assert_equal 0, @list.wizard_job_progress
    assert_includes @list.wizard_job_error, "AI service timeout"
  end

  test "job fails immediately if raw_html is blank" do
    @list.update!(raw_html: nil)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal "failed", @list.wizard_job_status
    assert_includes @list.wizard_job_error, "raw_html is blank"
  end

  test "job is idempotent - clears old unverified items" do
    # Create existing unverified items
    @list.list_items.create!(listable_type: "Music::Song", verified: false, position: 1)
    @list.list_items.create!(listable_type: "Music::Song", verified: false, position: 2)

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(
      OpenStruct.new(success: true, data: {songs: [{rank: 1, title: "New Song", artists: ["Artist"], album: nil, release_year: nil}]})
    )

    assert_difference "@list.list_items.unverified.count", -1 do  # 2 deleted, 1 added
      Music::Songs::WizardParseListJob.new.perform(@list.id)
    end

    @list.reload
    assert_equal 1, @list.list_items.unverified.count
    assert_equal "New Song", @list.list_items.first.metadata["title"]
  end

  test "job uses sequential positions when rank is null" do
    parsed_songs = [
      {rank: nil, title: "Song A", artists: ["Artist A"], album: nil, release_year: nil},
      {rank: nil, title: "Song B", artists: ["Artist B"], album: nil, release_year: nil}
    ]

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(
      OpenStruct.new(success: true, data: {songs: parsed_songs})
    )

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    positions = @list.list_items.unverified.order(:position).pluck(:position)
    assert_equal [1, 2], positions
  end
end
```

---

### Controller Tests

**File**: `test/controllers/admin/music/songs/list_wizard_controller_test.rb` (MODIFY)

**Add Test Cases**:

```ruby
# Parse Step Tests

test "parse step loads HTML preview" do
  @list.update!(raw_html: "Test HTML content")
  get step_admin_songs_list_wizard_path(list_id: @list.id, step: "parse")

  assert_response :success
  assert_match "Test HTML", response.body
end

test "advancing from parse step enqueues job when idle" do
  @list.update!(wizard_state: {"current_step" => 1, "job_status" => "idle"})

  assert_enqueued_with(job: Music::Songs::WizardParseListJob, args: [@list.id]) do
    post advance_step_admin_songs_list_wizard_path(
      list_id: @list.id,
      step: "parse"
    )
  end

  assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "parse")
  assert_equal "Parsing started", flash[:notice]
end

test "advancing from parse step proceeds when job completed" do
  @list.update!(wizard_state: {"current_step" => 1, "job_status" => "completed"})

  post advance_step_admin_songs_list_wizard_path(
    list_id: @list.id,
    step: "parse"
  )

  @list.reload
  assert_equal 2, @list.wizard_current_step  # Advanced to enrich
  assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "enrich")
end

test "advancing from parse step blocks when job running" do
  @list.update!(wizard_state: {"current_step" => 1, "job_status" => "running"})

  post advance_step_admin_songs_list_wizard_path(
    list_id: @list.id,
    step: "parse"
  )

  @list.reload
  assert_equal 1, @list.wizard_current_step  # Stayed on parse
  assert_redirected_to step_admin_songs_list_wizard_path(list_id: @list.id, step: "parse")
  assert_equal "Parsing in progress, please wait", flash[:alert]
end
```

---

### Component Tests

**File**: `test/components/admin/music/songs/wizard/parse_step_component_test.rb` (MODIFY)

**Add Test Cases**:

```ruby
require "test_helper"

class Admin::Music::Songs::Wizard::ParseStepComponentTest < ViewComponent::TestCase
  setup do
    @list = music_songs_lists(:with_raw_html)
    @list.update!(raw_html: "Sample HTML content for testing")
  end

  test "renders HTML preview" do
    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_text "HTML Preview"
    assert_text "Sample HTML content"
  end

  test "renders progress bar with current progress" do
    @list.update!(wizard_state: {"job_progress" => 50})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_selector "progress[value='50'][max='100']"
  end

  test "renders Start Parsing button when job idle" do
    @list.update!(wizard_state: {"job_status" => "idle"})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_selector "input[type='submit'][value='Start Parsing']"
  end

  test "does not render Start Parsing button when job running" do
    @list.update!(wizard_state: {"job_status" => "running"})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_no_selector "input[type='submit'][value='Start Parsing']"
  end

  test "renders error message when job failed" do
    @list.update!(wizard_state: {"job_status" => "failed", "job_error" => "Test error message"})

    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_selector ".alert-error"
    assert_text "Test error message"
  end

  test "uses wizard-step controller" do
    render_inline(Admin::Music::Songs::Wizard::ParseStepComponent.new(list: @list))

    assert_selector "[data-controller='wizard-step']"
  end
end
```

---

## Behavioral Rules

### Job Execution Rules

1. **Idempotency**: Job can be safely retried without creating duplicate list_items
   - Implementation: Delete all unverified list_items before creating new ones

2. **Atomicity**: Either all list_items are created or none are created
   - Implementation: Use transaction for list_item creation

3. **Progress Updates**: wizard_state updated at key milestones
   - Start: `{status: "running", progress: 0}`
   - Complete: `{status: "completed", progress: 100, metadata: {total_items: N}}`
   - Failure: `{status: "failed", progress: 0, error: "message"}`

4. **Error Recovery**: Failed jobs should allow retry
   - Implementation: Clear failed state before retry
   - UI: Show "Start Parsing" button again when status is "failed"

### UI Polling Rules

1. **Auto-Start**: Polling starts automatically if job_status is "running" on page load
2. **Auto-Stop**: Polling stops when job_status is "completed" or "failed"
3. **Button States**:
   - "Start Parsing": Visible when status is "idle" or "failed"
   - "Next": Enabled only when status is "completed"
4. **Error Display**: Error message shown when status is "failed", hidden otherwise

### Navigation Rules

1. **Cannot Skip**: Cannot advance to enrich step until parsing completes
2. **Can Retry**: Can restart parsing if it failed
3. **Can Go Back**: Can return to source step (clears parse job status)

---

## Implementation Steps

### Phase 1: Background Job (Estimated: 2 hours)

1. **Create job file**
   - [ ] Generate file: `app/sidekiq/music/songs/wizard_parse_list_job.rb`
   - [ ] Include `Sidekiq::Job`
   - [ ] Define `perform(list_id)` method

2. **Implement job logic**
   - [ ] Find list by ID with error handling
   - [ ] Validate raw_html presence
   - [ ] Clear existing unverified list_items
   - [ ] Update wizard_state to "running"
   - [ ] Call AI parser service
   - [ ] Extract parsed songs from result
   - [ ] Create list_items with metadata
   - [ ] Update wizard_state to "completed" with metadata
   - [ ] Add error handling and wizard_state "failed" updates
   - [ ] Add logging for all steps

3. **Write job tests**
   - [ ] Create test file: `test/sidekiq/music/songs/wizard_parse_list_job_test.rb`
   - [ ] Test successful parsing flow
   - [ ] Test error handling (missing HTML, AI failure)
   - [ ] Test idempotency
   - [ ] Test position assignment (with and without ranks)
   - [ ] Run tests: `bin/rails test test/sidekiq/music/songs/wizard_parse_list_job_test.rb`

### Phase 2: View Component (Estimated: 1.5 hours)

4. **Update parse step component template**
   - [ ] Open: `app/components/admin/music/songs/wizard/parse_step_component.html.erb`
   - [ ] Add Stimulus controller wrapper
   - [ ] Add HTML preview section
   - [ ] Add progress bar with target
   - [ ] Add status text with target
   - [ ] Add error display area
   - [ ] Add "Start Parsing" button (conditional on job_status)

5. **Update parse step component class**
   - [ ] Open: `app/components/admin/music/songs/wizard/parse_step_component.rb`
   - [ ] Accept `list:` and `raw_html_preview:` parameters
   - [ ] Pass data to template

6. **Add helper method**
   - [ ] Open: `app/helpers/admin/music/songs/list_wizard_helper.rb`
   - [ ] Add `job_status_text(list)` helper method

7. **Write component tests**
   - [ ] Update: `test/components/admin/music/songs/wizard/parse_step_component_test.rb`
   - [ ] Test HTML preview rendering
   - [ ] Test progress bar rendering
   - [ ] Test button states (idle vs running vs completed)
   - [ ] Test error display
   - [ ] Run tests: `bin/rails test test/components/admin/music/songs/wizard/parse_step_component_test.rb`

### Phase 3: Controller Integration (Estimated: 1 hour)

8. **Update controller**
   - [ ] Open: `app/controllers/admin/music/songs/list_wizard_controller.rb`
   - [ ] Add `load_parse_step_data` method
   - [ ] Add `advance_from_parse_step` method
   - [ ] Update `advance_step` to call `advance_from_parse_step` when step is "parse"
   - [ ] Add "parse" case to `load_step_data` case statement

9. **Write controller tests**
   - [ ] Update: `test/controllers/admin/music/songs/list_wizard_controller_test.rb`
   - [ ] Test parse step data loading
   - [ ] Test job enqueue on advance
   - [ ] Test blocking when job running
   - [ ] Test advancing when job completed
   - [ ] Run tests: `bin/rails test test/controllers/admin/music/songs/list_wizard_controller_test.rb`

### Phase 4: Integration Testing (Estimated: 1 hour)

10. **Manual browser testing**
    - [ ] Start Rails server and Sidekiq
    - [ ] Create test list with raw_html
    - [ ] Navigate to wizard
    - [ ] Select "Custom HTML" source
    - [ ] Verify parse step loads correctly
    - [ ] Click "Start Parsing"
    - [ ] Verify polling updates progress
    - [ ] Verify job completes successfully
    - [ ] Verify list_items created
    - [ ] Verify "Next" button enables
    - [ ] Test error case (blank HTML)
    - [ ] Test retry after failure

11. **Full test suite**
    - [ ] Run all wizard tests: `bin/rails test test/controllers/admin/music/songs/list_wizard_controller_test.rb test/sidekiq/music/songs/ test/components/admin/music/songs/wizard/`
    - [ ] Verify 0 failures
    - [ ] Fix any integration issues

12. **Code review checklist**
    - [ ] All acceptance criteria met
    - [ ] Error handling comprehensive
    - [ ] Logging appropriate
    - [ ] No N+1 queries
    - [ ] Idempotency verified
    - [ ] Edge cases covered

---

## Validation Checklist (Definition of Done)

- [ ] Background job exists and tested (7+ tests passing)
- [ ] Job creates list_items correctly
- [ ] Job updates wizard_state at all stages
- [ ] Job handles errors gracefully
- [ ] Job is idempotent
- [ ] View component renders all UI elements
- [ ] Component tests pass (6+ tests)
- [ ] Controller enqueues job correctly
- [ ] Controller blocks advance until job complete
- [ ] Controller tests pass (3+ new tests)
- [ ] Polling updates progress in real-time
- [ ] Error messages display correctly
- [ ] Navigation flow works end-to-end
- [ ] All tests pass (16+ new tests total)
- [ ] No N+1 queries introduced
- [ ] Documentation updated

---

## Dependencies

### Depends On (Completed)
- ✅ [086] Infrastructure - wizard_state, routes, model helpers
- ✅ [087] Wizard UI Shell - WizardController, polling Stimulus controller
- ✅ [088] Step 0: Import Source - import_source selection, conditional routing

### Needed By (Blocked Until This Completes)
- [090] Step 2: Enrich - Requires list_items with metadata to enrich
- [091] Step 3: Validation - Requires enriched list_items to validate
- [092] Step 4: Review UI - Requires validated list_items to display

### External References
- **AI Parser Service**: `app/lib/services/ai/tasks/lists/music/songs_raw_parser_task.rb` (lines 1-72)
- **Base Parser Task**: `app/lib/services/ai/tasks/lists/base_raw_parser_task.rb` (lines 1-86)
- **ListItem Model**: `app/models/list_item.rb` (lines 1-70)
- **Job Pattern**: `app/sidekiq/music/songs/import_list_items_from_json_job.rb` (lines 1-21)

---

## Related Tasks

- **Previous**: [088] Song Step 0: Import Source Choice
- **Next**: [090] Song Step 2: Enrich
- **Reference**: Existing parser service (no changes needed)

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns (Sidekiq jobs, ViewComponents, polling)
- Do not duplicate authoritative code; **link to files by path**
- Respect snippet budget (≤40 lines per snippet)
- Use `insert_all` for bulk inserts (performance)
- Update wizard_state atomically at all stages
- Make job idempotent (can retry safely)

### Required Outputs
- New file: `app/sidekiq/music/songs/wizard_parse_list_job.rb`
- New file: `test/sidekiq/music/songs/wizard_parse_list_job_test.rb`
- Modified: `app/components/admin/music/songs/wizard/parse_step_component.html.erb`
- Modified: `app/components/admin/music/songs/wizard/parse_step_component.rb`
- Modified: `app/controllers/admin/music/songs/list_wizard_controller.rb`
- Modified: `app/helpers/admin/music/songs/list_wizard_helper.rb`
- Modified: `test/controllers/admin/music/songs/list_wizard_controller_test.rb`
- Modified: `test/components/admin/music/songs/wizard/parse_step_component_test.rb`
- Passing tests for all new functionality (16+ tests)
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1. **codebase-pattern-finder** → Find Sidekiq job patterns, list_item creation patterns
2. **codebase-analyzer** → Verify AI parser service interface, wizard_state structure
3. **technical-writer** → Update docs after implementation, create job documentation

### Test Fixtures
- Use existing `music_songs_lists(:basic_list)` fixture
- Add fixture for list with raw_html: `music_songs_lists(:with_raw_html)`
- Mock AI parser service responses in tests (use `stubs` or VCR)

---

## Implementation Notes

(To be filled during implementation)

### Files Created
- [ ] TBD

### Files Modified
- [ ] TBD

### Test Results
- [ ] TBD

### Deviations from Plan
- [ ] TBD

---

## Documentation Updated

- [ ] This task file updated with implementation notes
- [ ] Job documentation created at `/home/shane/dev/the-greatest/docs/sidekiq/music/songs/wizard_parse_list_job.md`
- [ ] Cross-references updated in related task files

---

## Notes

### Performance Considerations
- AI parsing typically takes 10-30 seconds for 100 items
- Use `insert_all` to avoid N+1 during list_item creation
- Polling interval of 2 seconds is sufficient (no real-time sub-second updates needed)

### Security Considerations
- Job runs in background worker (no direct user input in job)
- List ID validated by ActiveRecord (raises if not found)
- wizard_state updates use ActiveRecord (prevents SQL injection)
- No user-provided HTML executed (only displayed as text preview)

### Future Enhancements (Out of Scope)
- [ ] Streaming progress updates (0-100% based on item count)
- [ ] Retry logic with exponential backoff
- [ ] Cancellation support (kill running job)
- [ ] Batch processing for very large lists (> 1000 items)

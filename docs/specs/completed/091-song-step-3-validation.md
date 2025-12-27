# [091] - Song Wizard: Step 3 - AI Validation

## Status
- **Status**: Completed
- **Completed**: 2025-12-03
- **Priority**: High
- **Created**: 2025-01-19
- **Part**: 6 of 10

## Overview
Implement Step 3 of the song list wizard where enriched `list_items` (created in Step 2: Enrich) are validated using AI to detect bad matches (live vs studio, covers, different artists, etc.). This step validates **ALL enriched items** (both OpenSearch and MusicBrainz matches) against the original list data - not just MusicBrainz matches like the existing Avo workflow.

Key outcomes:
- **Invalid matches**: Flagged with `metadata["ai_match_invalid"] = true`
- **Valid matches**: Marked with `verified = true` on the ListItem record

This approach recognizes that OpenSearch matches can also be wrong (false positives from fuzzy matching), and that AI-validated matches should be marked as verified to give users confidence.

## Context

This is **Part 6 of 10** in the Song List Wizard implementation:

1. [086] Infrastructure ✅ Complete
2. [087] Wizard UI Shell ✅ Complete
3. [088] Step 0: Import Source Choice ✅ Complete
4. [089] Step 1: Parse HTML ✅ Complete
5. [090] Step 2: Enrich ✅ Complete
6. **[091] Step 3: Validation** ← You are here
7. [092] Step 4: Review UI
8. [093] Step 4: Actions
9. [094] Step 5: Import
10. [095] Polish & Integration

### The Flow

**Custom HTML Path**:
```
Step 0 (source) → Step 1 (parse) → Step 2 (enrich) → Step 3 (validate) → ...
```

### What This Builds

This task implements:
- Validate step view component with stats display, progress tracking UI, and validation results preview
- Background job (`Music::Songs::WizardValidateListItemsJob`) that:
  - Iterates through unverified `list_items` with MusicBrainz matches (`mb_recording_id` present)
  - Builds a numbered list of Original→Matched pairs
  - Calls AI service for batch validation
  - Updates `list_item.metadata["ai_match_invalid"]` flag based on AI response
  - Updates wizard_state with job progress
- New AI task service (`Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask`) adapted from the existing `ItemsJsonValidatorTask`
- Controller logic to enqueue validate job and handle step advancement

This task does NOT implement:
- User review/correction UI (covered in [092])
- Import logic (covered in [094])
- Any changes to the existing `ItemsJsonValidatorTask` (kept for Avo compatibility)

### Key Design Decisions

**New Service vs Refactoring**:
- **Decision**: Create new `ListItemsValidatorTask` rather than modifying existing `ItemsJsonValidatorTask`
- **Why**:
  - Existing service works with `items_json["songs"]` (Avo workflow)
  - New service works with `list_items.metadata` (Wizard workflow)
  - Keep both workflows functional independently
  - AI prompt and response format are identical, only data source differs

**Job vs Service Pattern**:
- **Job**: `Music::Songs::WizardValidateListItemsJob` - Sidekiq job for async execution, handles progress updates
- **Service**: `Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask` - Calls AI, processes response, updates list_items
- **Why**: Separate orchestration (job) from AI interaction logic (service) for testability

**Validation Scope**:
- Validates ALL enriched items (items with `listable_id` OR `mb_recording_id` OR `song_id` in metadata)
- Includes OpenSearch matches - these can also be wrong (fuzzy matching false positives)
- Includes MusicBrainz matches - same as existing Avo workflow
- Items without any match are skipped (nothing to validate)

**Why Validate OpenSearch Matches?**:
- OpenSearch uses fuzzy matching with a score threshold (5.0)
- A song titled "Time" by Pink Floyd could match "Time" by a different artist
- Local database matches are not guaranteed to be correct
- The original Avo workflow only validated MusicBrainz matches, but this was an oversight

**Progress Tracking Approach**:
- Use `list.update_wizard_step_status(step: "validate", status:, progress:, metadata:)` helper
- Single AI call (not per-item), so progress is: 0% → (running) → 100%
- Metadata includes: `validated_items`, `valid_count`, `invalid_count`, `reasoning`
- Polling frequency: 2 seconds (defined in `wizard_step_controller.js`)

**Data Storage**:
- **Invalid matches**: Set `metadata["ai_match_invalid"] = true`, leave `verified = false`
- **Valid matches**: Remove `ai_match_invalid` key (if present), set `verified = true`
- This gives users immediate confidence in AI-validated matches
- Items flagged as invalid remain unverified for manual review in the Review step

---

## Requirements

### Functional Requirements

#### FR-1: Validate Step View Component
**Contract**: Display validation stats, job status, progress bar, results preview, and navigation controls

**UI States**:

**State 1 - Idle (Ready to Validate)**:
- Shows count of items with MusicBrainz matches (items to validate)
- Info alert explaining what validation does
- "Start Validation" button (enabled)
- Stats cards showing: Total items, Items with MB matches, Items to validate

**State 2 - Running**:
- Progress bar (0-100%)
- Status text: "Validating matches with AI..."
- Animated loading indicator
- "Start Validation" button hidden or disabled

**State 3 - Completed**:
- Success message: "Validation Complete!"
- Stats cards showing:
  - Total validated (count)
  - Valid matches (count + percentage)
  - Invalid matches (count + percentage)
- AI reasoning displayed
- Preview table of validation results (shows Valid/Invalid badge per item)
- "Continue to Review" button (enabled)
- "Re-validate" button (to restart if needed)

**State 4 - Failed**:
- Error message with details
- "Retry Validation" button

**Stimulus Controller Integration**:
- Uses `wizard_step_controller.js` (already implemented)
- Targets: `progressBar`, `statusText`
- Conditionally attached only when job is "running"
- Auto-refreshes via Turbo visit when job completes

**Implementation**: `app/components/admin/music/songs/wizard/validate_step_component.html.erb`

#### FR-2: Background Job for Validation
**Contract**: Validate enriched list_items asynchronously with progress tracking

**Job Specification**:
- **File**: `app/sidekiq/music/songs/wizard_validate_list_items_job.rb`
- **Queue**: `default` (standard Sidekiq queue)
- **Parameters**: `list_id` (integer)

**Job Workflow**:
1. Find list by ID
2. Validate preconditions (has items with `mb_recording_id`)
3. Update wizard_state: `{job_status: "running", job_progress: 0}`
4. Clear previous validation flags (for idempotency)
5. Call `Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.new(parent: list).call`
6. Extract validation results from AI response
7. Update each list_item's metadata with validation result
8. Update wizard_state: `{job_status: "completed", job_progress: 100, job_metadata: {stats}}`
9. Handle errors and update wizard_state accordingly

**Error Handling**:
- AI service failures: Log error, update wizard_state with error message
- Database errors: Log error, update wizard_state with error message
- No items to validate: Complete immediately with zero counts (not an error)

**Implementation Pattern**: Reference `wizard_enrich_list_items_job.rb`

#### FR-3: AI Validation Service
**Contract**: Use AI to validate MusicBrainz matches against original list data

**Service Specification**:
- **File**: `app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb`
- **Pattern**: Extends `Services::Ai::Tasks::BaseTask`
- **Input**: `ListItemsValidatorTask.new(parent: list)`

**Validation Logic** (same as existing `ItemsJsonValidatorTask`):

**A match is INVALID if**:
- Live recordings matched with studio recordings (e.g., "Imagine" ≠ "Imagine (Live)")
- Cover versions matched with originals (different artists)
- Different recordings with similar titles (e.g., "Johnny B. Goode" by Chuck Berry ≠ by Jimi Hendrix)
- Remix or alternate versions matched with originals
- Significant artist name differences suggesting different works

**A match is VALID if**:
- Same recording with minor formatting differences
- Different releases of same recording (single, album, compilation)
- Artist name variations (e.g., "The Beatles" vs "Beatles")
- Minor subtitle differences for the same recording

**User Prompt Construction**:
```
1. Original: "The Beatles - Come Together" → Matched: "The Beatles - Come Together" [OpenSearch]
2. Original: "John Lennon - Imagine" → Matched: "John Lennon - Imagine (Live)" [MusicBrainz]
3. Original: "Pink Floyd - Time" → Matched: "Morris Day and the Time - The Time" [OpenSearch]
...
```

The `[OpenSearch]` or `[MusicBrainz]` tag helps the AI understand the match source, though validation criteria are the same for both.

**AI Response Schema**:
```ruby
{
  invalid: [2],  # Array of numbers for invalid matches
  reasoning: "Item 2 is a live version, not the studio recording"
}
```

**Output** (Result object):
```ruby
{
  success: true,
  data: {
    valid_count: 45,
    invalid_count: 5,
    total_count: 50,
    reasoning: "..."
  },
  ai_chat: <AiChat record>
}
```

**Reference Implementation**: `app/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.rb`

#### FR-4: Controller Integration
**Contract**: Enqueue validation job and handle step advancement

**Method Updates**:

1. **`load_validate_step_data`** (currently empty at line 98-99):
   ```ruby
   def load_validate_step_data
     @unverified_items = @list.list_items.unverified.ordered
     @enriched_items = @unverified_items.select do |item|
       item.listable_id.present? ||
         item.metadata["song_id"].present? ||
         item.metadata["mb_recording_id"].present?
     end
     @total_items = @unverified_items.count
     @items_to_validate = @enriched_items.count
   end
   ```

2. **`enqueue_validate_job`** (currently empty at line 119-120):
   ```ruby
   def enqueue_validate_job
     Music::Songs::WizardValidateListItemsJob.perform_async(wizard_entity.id)
   end
   ```

3. **`advance_step` override** (add "validate" case to lines 19-29):
   - Similar pattern to `advance_from_enrich_step`
   - If idle/failed: Set status to "running", enqueue job, redirect to validate step
   - If completed: Advance to review step
   - If running: Show "in progress" alert

**Implementation Location**: `app/controllers/admin/music/songs/list_wizard_controller.rb`

---

### Non-Functional Requirements

#### NFR-1: Performance
- [ ] AI validation completes in < 60 seconds for lists with < 100 items
- [ ] AI validation completes in < 120 seconds for lists with 100-500 items
- [ ] Single AI call per validation run (batch all items)
- [ ] Polling adds < 10ms overhead per request

#### NFR-2: Data Integrity
- [ ] Job is idempotent (can be safely retried)
- [ ] Previous validation flags cleared before re-validation
- [ ] wizard_state updates are atomic
- [ ] Failed jobs do not corrupt existing metadata

#### NFR-3: Error Handling
- [ ] AI service timeout handled gracefully
- [ ] Empty result (no items to validate) handled gracefully
- [ ] Network errors logged and surfaced to user
- [ ] AI response parsing errors handled

#### NFR-4: Observability
- [ ] Job start/completion logged with metadata
- [ ] AI service call logged with duration
- [ ] Errors include full context for debugging
- [ ] Final stats logged at info level

---

## Contracts & Schemas

### ListItem Metadata Schema (After Validation)

**Additional fields added** (to existing enrichment metadata):

```json
{
  "ai_match_invalid": true  // Only present if match is invalid
}
```

**Note**: Valid matches have this key removed (not set to `false`).

### Endpoint Table

| Verb | Path | Purpose | Params/Body | Auth | Response |
|------|------|---------|-------------|------|----------|
| GET | `/wizard/step/validate` | Show validate step | - | admin | HTML (Turbo Frame) |
| POST | `/wizard/step/validate/advance` | Start validation job or advance | step="validate" | admin | 302 redirect |
| GET | `/wizard/step/validate/status` | Get job status | step="validate" | admin | JSON (status endpoint schema) |

### Status Endpoint Response

**Endpoint**: `GET /admin/songs/lists/:list_id/wizard/step_status?step=validate`

**Response** (running):
```json
{
  "status": "running",
  "progress": 0,
  "error": null,
  "metadata": {}
}
```

**Response** (completed):
```json
{
  "status": "completed",
  "progress": 100,
  "error": null,
  "metadata": {
    "validated_items": 50,
    "valid_count": 45,
    "invalid_count": 5,
    "reasoning": "5 items flagged: 3 live recordings, 2 cover versions",
    "validated_at": "2025-01-23T15:30:00Z"
  }
}
```

**Response** (failed):
```json
{
  "status": "failed",
  "progress": 0,
  "error": "AI service timeout",
  "metadata": {}
}
```

### Wizard State Update

**Before** (after enrich step):
```json
{
  "current_step": 3,
  "import_source": "custom_html",
  "steps": {
    "parse": { "status": "completed", ... },
    "enrich": { "status": "completed", ... },
    "validate": {
      "status": "idle",
      "progress": 0,
      "error": null,
      "metadata": {}
    }
  }
}
```

**During validation**:
```json
{
  "current_step": 3,
  "steps": {
    "validate": {
      "status": "running",
      "progress": 0,
      "error": null,
      "metadata": {}
    }
  }
}
```

**After successful validation**:
```json
{
  "current_step": 3,
  "steps": {
    "validate": {
      "status": "completed",
      "progress": 100,
      "error": null,
      "metadata": {
        "validated_items": 50,
        "valid_count": 45,
        "invalid_count": 5,
        "reasoning": "5 items flagged...",
        "validated_at": "2025-01-23T15:30:00Z"
      }
    }
  }
}
```

---

## Acceptance Criteria

### View Component
- [ ] `Admin::Music::Songs::Wizard::ValidateStepComponent` renders all UI states
- [ ] Stats cards show: Total items, Items with MB matches, Valid count, Invalid count
- [ ] "Start Validation" button exists when job idle/failed
- [ ] Progress bar exists with `data-wizard-step-target="progressBar"` attribute
- [ ] Status text exists with `data-wizard-step-target="statusText"` attribute
- [ ] Error display area shown when job failed
- [ ] Preview table shows validated items with Valid/Invalid badges
- [ ] AI reasoning displayed after completion
- [ ] Uses Stimulus controller conditionally (only when running)
- [ ] Turbo visit auto-refreshes on job completion

### Background Job
- [ ] `Music::Songs::WizardValidateListItemsJob` exists in correct namespace
- [ ] Job updates wizard_step_status to "running" at start
- [ ] Job processes ALL enriched items (with `listable_id` OR `song_id` OR `mb_recording_id`)
- [ ] Job calls `ListItemsValidatorTask` for AI validation
- [ ] Job updates wizard_step_status to "completed" on success with final stats
- [ ] Job updates wizard_step_status to "failed" on error
- [ ] Job logs all important events (start, success, failure)
- [ ] Job is idempotent (clears previous validation flags on retry)
- [ ] Job handles empty list (no enriched items) gracefully
- [ ] Job sets `verified = true` on valid items
- [ ] Job clears `listable_id` on invalid OpenSearch matches

### AI Service
- [ ] `Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask` exists
- [ ] Service builds numbered list of Original→Matched pairs (both OpenSearch and MusicBrainz)
- [ ] Service includes match source tag `[OpenSearch]` or `[MusicBrainz]` in prompt
- [ ] Service sends single AI request for batch validation
- [ ] Service parses AI response (invalid array + reasoning)
- [ ] Service updates each list_item's metadata with ai_match_invalid flag
- [ ] Service removes ai_match_invalid for valid items (idempotent)
- [ ] Service sets `verified = true` for valid items
- [ ] Service clears `listable_id` for invalid OpenSearch matches
- [ ] Service returns result with valid_count, invalid_count, verified_count, total_count, reasoning
- [ ] Service handles AI errors gracefully

### Controller Logic
- [ ] `load_validate_step_data` loads item counts and enriched item count
- [ ] `enqueue_validate_job` calls the Sidekiq job
- [ ] `advance_from_validate_step` implemented with correct pattern
- [ ] Cannot advance if job not completed
- [ ] Can advance to review step when job completed
- [ ] Flash alert shown if trying to advance prematurely
- [ ] Supports re-validation via `revalidate` param

### Progress Tracking
- [ ] Polling starts automatically when step loads with running job
- [ ] Progress bar shows 0% during AI call, 100% on completion
- [ ] Status text shows "Validating matches with AI..."
- [ ] Error message displayed if job fails
- [ ] Continue button enabled when job completes

### Error Handling
- [ ] Empty list (no enriched items) handled gracefully (0/0/0/0 counts)
- [ ] AI service timeout shows user-friendly message
- [ ] AI response parsing errors handled
- [ ] Network errors logged and displayed

### Data Integrity
- [ ] Valid items get `verified = true`
- [ ] Invalid items get `ai_match_invalid = true` and remain `verified = false`
- [ ] Invalid OpenSearch matches get `listable_id` cleared (was wrong match)
- [ ] Re-validation clears previous flags and re-evaluates all items

---

## Golden Examples

### Example 1: Successful Validation Flow

**Input** (ListItems from enrich step):
```ruby
# Item 1: Valid OpenSearch match
ListItem.new(
  position: 1,
  listable_id: 123,  # Linked to Music::Song
  verified: false,
  metadata: {
    "title" => "Come Together",
    "artists" => ["The Beatles"],
    "song_id" => 123,
    "song_name" => "Come Together",
    "opensearch_match" => true,
    "opensearch_score" => 18.5
  }
)

# Item 2: Invalid MusicBrainz match (live version)
ListItem.new(
  position: 2,
  listable_id: nil,  # Not linked yet
  verified: false,
  metadata: {
    "title" => "Imagine",
    "artists" => ["John Lennon"],
    "mb_recording_id" => "a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
    "mb_recording_name" => "Imagine (Live)",
    "mb_artist_names" => ["John Lennon"],
    "musicbrainz_match" => true
  }
)

# Item 3: Invalid OpenSearch match (wrong song!)
ListItem.new(
  position: 3,
  listable_id: 789,  # Linked but WRONG
  verified: false,
  metadata: {
    "title" => "Time",
    "artists" => ["Pink Floyd"],
    "song_id" => 789,
    "song_name" => "The Time",  # Wrong song - by Morris Day!
    "opensearch_match" => true,
    "opensearch_score" => 5.2  # Low score, fuzzy match
  }
)

# Item 4: No match (skipped from validation)
ListItem.new(
  position: 4,
  listable_id: nil,
  verified: false,
  metadata: {
    "title" => "Obscure B-Side",
    "artists" => ["Unknown Artist"]
    # No song_id, no mb_recording_id - nothing to validate
  }
)
```

**AI Prompt Sent**:
```
Validate these song recording matches. Original songs from the list are matched with database/MusicBrainz data.
Identify any invalid matches where the original and matched recordings are different works.

1. Original: "The Beatles - Come Together" → Matched: "Come Together" [OpenSearch]
2. Original: "John Lennon - Imagine" → Matched: "Imagine (Live)" [MusicBrainz]
3. Original: "Pink Floyd - Time" → Matched: "The Time" [OpenSearch]

Which matches are invalid? Return array of numbers for invalid matches.
```

**AI Response**:
```json
{
  "invalid": [2, 3],
  "reasoning": "Item 2: 'Imagine (Live)' is a live recording, not the studio version. Item 3: 'The Time' by Morris Day is completely different from Pink Floyd's 'Time'."
}
```

**Output** (ListItems after validation):
```ruby
# Item 1: Valid - now verified!
ListItem(
  listable_id: 123,
  verified: true,  # MARKED VERIFIED!
  metadata: {
    "title" => "Come Together",
    "opensearch_match" => true,
    # No ai_match_invalid key
  }
)

# Item 2: Invalid MusicBrainz match
ListItem(
  listable_id: nil,
  verified: false,  # Still unverified
  metadata: {
    "title" => "Imagine",
    "musicbrainz_match" => true,
    "ai_match_invalid" => true  # FLAGGED!
  }
)

# Item 3: Invalid OpenSearch match - listable_id cleared!
ListItem(
  listable_id: nil,  # CLEARED - was wrong match
  verified: false,
  metadata: {
    "title" => "Time",
    "opensearch_match" => true,
    "ai_match_invalid" => true  # FLAGGED!
  }
)

# Item 4: Unchanged (wasn't validated - no match to check)
ListItem(
  listable_id: nil,
  verified: false,
  metadata: {
    "title" => "Obscure B-Side"
  }
)
```

**Final wizard_step_metadata**:
```json
{
  "validated_items": 3,
  "valid_count": 1,
  "invalid_count": 2,
  "verified_count": 1,
  "reasoning": "Item 2: 'Imagine (Live)' is a live recording... Item 3: 'The Time' is completely different...",
  "validated_at": "2025-01-23T15:30:45Z"
}
```

### Example 2: No Items to Validate

**Input**: All items have no enrichment (no `listable_id`, no `song_id`, no `mb_recording_id`)

**Job Behavior**:
1. Job starts
2. Detects 0 enriched items
3. Completes immediately (no AI call needed)

**Final wizard_step_status**:
```json
{
  "status": "completed",
  "progress": 100,
  "error": null,
  "metadata": {
    "validated_items": 0,
    "valid_count": 0,
    "invalid_count": 0,
    "verified_count": 0,
    "reasoning": "No enriched items to validate",
    "validated_at": "2025-01-23T15:30:45Z"
  }
}
```

### Example 3: AI Service Failure

**Input**: Valid items, but AI service times out

**Job Behavior**:
1. Job starts
2. AI service call times out
3. Updates wizard_state with error

**Final wizard_step_status**:
```json
{
  "status": "failed",
  "progress": 0,
  "error": "AI validation failed: Request timeout after 60 seconds",
  "metadata": {}
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
│   │           └── wizard_validate_list_items_job.rb    # NEW: Background job
│   ├── lib/
│   │   └── services/
│   │       └── ai/
│   │           └── tasks/
│   │               └── lists/
│   │                   └── music/
│   │                       └── songs/
│   │                           ├── items_json_validator_task.rb   # EXISTS: Keep unchanged
│   │                           └── list_items_validator_task.rb   # NEW: ListItem-based validator
│   ├── controllers/
│   │   └── admin/
│   │       └── music/
│   │           └── songs/
│   │               └── list_wizard_controller.rb       # MODIFY: Add validate logic
│   └── components/
│       └── admin/
│           └── music/
│               └── songs/
│                   └── wizard/
│                       ├── validate_step_component.rb     # MODIFY: Add logic
│                       └── validate_step_component.html.erb # MODIFY: Full UI
└── test/
    ├── sidekiq/
    │   └── music/
    │       └── songs/
    │           └── wizard_validate_list_items_job_test.rb  # NEW: Job tests
    ├── lib/
    │   └── services/
    │       └── ai/
    │           └── tasks/
    │               └── lists/
    │                   └── music/
    │                       └── songs/
    │                           └── list_items_validator_task_test.rb # NEW: Service tests
    ├── controllers/
    │   └── admin/
    │       └── music/
    │           └── songs/
    │               └── list_wizard_controller_test.rb    # MODIFY: Add validate tests
    └── components/
        └── admin/
            └── music/
                └── songs/
                    └── wizard/
                        └── validate_step_component_test.rb # NEW: Component tests
```

---

## Key Implementation Files

### 1. AI Validation Service (NEW)

**File**: `app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb`

**Reference Pattern**: `items_json_validator_task.rb` (lines 1-116)

**Key Differences from ItemsJsonValidatorTask**:
- Reads from `parent.list_items.unverified` instead of `parent.items_json["songs"]`
- Validates ALL enriched items (OpenSearch + MusicBrainz), not just MusicBrainz
- Updates `list_item.metadata["ai_match_invalid"]` instead of `song["ai_match_invalid"]`
- Sets `verified = true` on valid items
- Clears `listable_id` on invalid OpenSearch matches
- Includes match source tag `[OpenSearch]` or `[MusicBrainz]` in prompt

**Implementation** (reference only, ~80 lines):

```ruby
# reference only
module Services::Ai::Tasks::Lists::Music::Songs
  class ListItemsValidatorTask < Services::Ai::Tasks::BaseTask
    private

    def task_provider = :openai
    def task_model = "gpt-5-mini"
    def chat_type = :analysis
    def temperature = 1.0
    def response_format = {type: "json_object"}

    def system_message
      # Same as ItemsJsonValidatorTask
    end

    def enriched_items
      @enriched_items ||= parent.list_items.unverified.select do |item|
        item.listable_id.present? ||
          item.metadata["song_id"].present? ||
          item.metadata["mb_recording_id"].present?
      end
    end

    def user_prompt
      song_matches = enriched_items.map.with_index do |item, index|
        source = item.metadata["opensearch_match"] ? "OpenSearch" : "MusicBrainz"
        matched_name = item.metadata["song_name"] || item.metadata["mb_recording_name"]
        # Build "N. Original: \"Artist - Title\" → Matched: \"Name\" [Source]"
      end.join("\n")
      # Return prompt
    end

    def process_and_persist(provider_response)
      # Parse invalid array
      # For valid items: remove ai_match_invalid, set verified = true
      # For invalid items: set ai_match_invalid = true, clear listable_id if OpenSearch
      # Return Result with counts including verified_count
    end
  end
end
```

### 2. Background Job (NEW)

**File**: `app/sidekiq/music/songs/wizard_validate_list_items_job.rb`

**Reference Pattern**: `wizard_enrich_list_items_job.rb`

**Implementation** (reference only, ~50 lines):

```ruby
# reference only
class Music::Songs::WizardValidateListItemsJob
  include Sidekiq::Job

  def perform(list_id)
    @list = Music::Songs::List.find(list_id)
    items_to_validate = @list.list_items.unverified.select { |i| i.metadata["mb_recording_id"].present? }

    if items_to_validate.empty?
      complete_with_no_items
      return
    end

    @list.update_wizard_step_status(step: "validate", status: "running", progress: 0)
    clear_previous_validation_flags

    result = Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.new(parent: @list).call

    if result.success?
      complete_job(result.data)
    else
      handle_error(result.error || "Validation failed")
    end
  rescue => e
    handle_error(e.message)
    raise
  end

  private

  # ... helper methods
end
```

### 3. Validate Step Component (MODIFY)

**File**: `app/components/admin/music/songs/wizard/validate_step_component.rb`

**Current State**: Minimal stub (11 lines)

**Required Changes**: Add helper methods following enrich_step_component.rb pattern

**Implementation** (reference only, ~60 lines):

```ruby
# reference only
class Admin::Music::Songs::Wizard::ValidateStepComponent < ViewComponent::Base
  def initialize(list:, enriched_items: nil)
    @list = list
    @unverified_items = list.list_items.unverified.ordered
    @enriched_items = enriched_items || @unverified_items.select do |item|
      item.listable_id.present? ||
        item.metadata["song_id"].present? ||
        item.metadata["mb_recording_id"].present?
    end
  end

  private

  attr_reader :list, :unverified_items, :enriched_items

  def validate_status = list.wizard_step_status("validate")
  def validate_progress = list.wizard_step_progress("validate")
  def validate_error = list.wizard_step_error("validate")
  def job_metadata = list.wizard_step_metadata("validate")

  def valid_count = job_metadata["valid_count"] || 0
  def invalid_count = job_metadata["invalid_count"] || 0
  def verified_count = job_metadata["verified_count"] || 0
  def validated_items = job_metadata["validated_items"] || 0
  def reasoning = job_metadata["reasoning"]

  def idle_or_failed? = %w[idle failed].include?(validate_status)
  def running? = validate_status == "running"
  def completed? = validate_status == "completed"
  def failed? = validate_status == "failed"
end
```

### 4. Validate Step Component Template (MODIFY)

**File**: `app/components/admin/music/songs/wizard/validate_step_component.html.erb`

**Current State**: Basic progress bar stub (27 lines), uses deprecated `wizard_job_status`

**Required Changes**: Full UI with all 4 states, step-namespaced status

**Key UI Elements**:
- Conditional Stimulus controller attachment (only when running)
- Stats cards (total, valid, invalid)
- Progress bar with targets
- Results table showing Valid/Invalid badges per item
- AI reasoning display
- Start/Retry/Re-validate buttons based on state

### 5. Controller Modifications (MODIFY)

**File**: `app/controllers/admin/music/songs/list_wizard_controller.rb`

**Changes**:

1. Add `advance_from_validate_step` method (similar to `advance_from_enrich_step`)
2. Update `advance_step` to call `advance_from_validate_step` when step is "validate"
3. Implement `load_validate_step_data`
4. Implement `enqueue_validate_job`

---

## Testing Strategy

### AI Service Tests

**File**: `test/lib/services/ai/tasks/lists/music/songs/list_items_validator_task_test.rb` (NEW)

**Test Cases**:
```ruby
test "task_provider returns openai"
test "task_model returns gpt-5-mini"
test "chat_type returns analysis"
test "system_message contains validation instructions"
test "user_prompt includes OpenSearch matched items"
test "user_prompt includes MusicBrainz matched items"
test "user_prompt excludes items with no enrichment"
test "user_prompt numbers items starting from 1"
test "user_prompt formats Original → Matched with source tag"
test "process_and_persist marks invalid matches in metadata"
test "process_and_persist sets verified=true for valid matches"
test "process_and_persist clears listable_id for invalid OpenSearch matches"
test "process_and_persist removes ai_match_invalid for valid matches"
test "process_and_persist handles empty invalid array (all valid)"
test "process_and_persist returns correct counts including verified_count"
```

### Job Tests

**File**: `test/sidekiq/music/songs/wizard_validate_list_items_job_test.rb` (NEW)

**Test Cases**:
```ruby
test "job updates wizard_step_status to running at start"
test "job calls ListItemsValidatorTask"
test "job updates wizard_step_status to completed with stats on success"
test "job updates wizard_step_status to failed on error"
test "job handles empty list gracefully (no enriched items)"
test "job is idempotent - clears previous validation flags"
test "job is idempotent - resets verified to false before validation"
test "job raises error when list not found"
test "job logs completion with counts"
test "job validates both OpenSearch and MusicBrainz matches"
```

### Component Tests

**File**: `test/components/admin/music/songs/wizard/validate_step_component_test.rb` (NEW)

**Test Cases**:
```ruby
test "renders stats cards"
test "renders progress bar with current progress"
test "renders Start Validation button when job idle"
test "does not render Start Validation button when job running"
test "renders error message when job failed"
test "uses wizard-step controller when job is running"
test "does not use wizard-step controller when job is idle"
test "displays results table when completed"
test "shows AI reasoning when completed"
test "displays Valid/Invalid/Verified badges correctly"
test "shows verified count in stats when completed"
```

### Controller Tests

**File**: `test/controllers/admin/music/songs/list_wizard_controller_test.rb` (MODIFY)

**Add Test Cases**:
```ruby
test "validate step loads item counts"
test "advancing from validate step enqueues job when idle"
test "advancing from validate step proceeds when job completed"
test "advancing from validate step blocks when job running"
test "revalidate param triggers re-validation"
```

---

## Behavioral Rules

### Job Execution Rules

1. **Idempotency**: Job can be safely retried
   - Clear `ai_match_invalid` from all items before validation
   - Reset `verified = false` on all unverified items before validation
   - Re-run AI validation from scratch

2. **Progress Updates**: wizard_step_status updated at key milestones
   - Start: `{status: "running", progress: 0}`
   - Complete: `{status: "completed", progress: 100, metadata: {counts...}}`
   - Failure: `{status: "failed", error: "message"}`

3. **Empty List Handling**: No enriched items is not an error
   - Complete immediately with zero counts
   - Reasoning: "No enriched items to validate"

4. **Invalid Match Handling**:
   - For invalid MusicBrainz matches: Set `ai_match_invalid = true`, keep `listable_id` nil
   - For invalid OpenSearch matches: Set `ai_match_invalid = true`, CLEAR `listable_id` (was wrong)
   - Invalid items remain `verified = false` for manual review

5. **Valid Match Handling**:
   - Remove `ai_match_invalid` key (if present from previous run)
   - Set `verified = true` on the ListItem
   - Keep `listable_id` intact

### UI Polling Rules

1. **Auto-Start**: Polling starts if validate_status is "running" on page load
2. **Auto-Stop**: Polling stops when status is "completed" or "failed"
3. **Turbo Visit**: Full page refresh when job completes
4. **Button States**:
   - "Start Validation": Visible when status is "idle" or "failed"
   - "Continue to Review": Enabled only when status is "completed"

### Navigation Rules

1. **Cannot Skip**: Cannot advance to review step until validation completes
2. **Can Retry**: Can restart validation if it failed
3. **Can Go Back**: Can return to enrich step (preserves validation status)

---

## Implementation Steps

### Phase 1: AI Service (Estimated: 1.5 hours)

1. **Create service file**
   - [ ] Create `app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb`
   - [ ] Copy structure from `items_json_validator_task.rb`
   - [ ] Modify to read from `list_items.unverified` instead of `items_json["songs"]`
   - [ ] Modify to update `list_item.metadata` instead of `song` hash

2. **Write service tests**
   - [ ] Create test file
   - [ ] Test user_prompt generation
   - [ ] Test process_and_persist logic
   - [ ] Test idempotent validation (re-validation clears previous flags)
   - [ ] Run tests

### Phase 2: Background Job (Estimated: 1.5 hours)

3. **Create job file**
   - [ ] Generate: `bin/rails generate sidekiq:job music/songs/wizard_validate_list_items`
   - [ ] Implement `perform(list_id)` method
   - [ ] Add wizard_step_status updates
   - [ ] Add error handling

4. **Write job tests**
   - [ ] Test successful validation flow
   - [ ] Test error handling
   - [ ] Test empty list handling
   - [ ] Test idempotency
   - [ ] Run tests

### Phase 3: View Component (Estimated: 1.5 hours)

5. **Update validate step component Ruby class**
   - [ ] Add helper methods following enrich_step_component pattern
   - [ ] Add step-specific status accessors

6. **Update validate step component template**
   - [ ] Add full UI with all 4 states
   - [ ] Add conditional Stimulus controller attachment
   - [ ] Add stats cards
   - [ ] Add results table
   - [ ] Add action buttons

7. **Write component tests**
   - [ ] Test all UI states
   - [ ] Test Stimulus controller attachment
   - [ ] Run tests

### Phase 4: Controller Integration (Estimated: 1 hour)

8. **Update controller**
   - [ ] Implement `load_validate_step_data`
   - [ ] Implement `enqueue_validate_job`
   - [ ] Add `advance_from_validate_step` method
   - [ ] Update `advance_step` case statement

9. **Write controller tests**
   - [ ] Test data loading
   - [ ] Test job enqueue
   - [ ] Test step advancement
   - [ ] Run tests

### Phase 5: Integration Testing (Estimated: 1 hour)

10. **Manual browser testing**
    - [ ] Start Rails server and Sidekiq
    - [ ] Navigate through wizard to validate step
    - [ ] Click "Start Validation"
    - [ ] Verify progress updates
    - [ ] Verify results display correctly
    - [ ] Test error case (mock AI failure)
    - [ ] Test retry after failure

11. **Full test suite**
    - [ ] Run all wizard tests
    - [ ] Verify 0 failures
    - [ ] Fix any integration issues

---

## Validation Checklist (Definition of Done)

- [ ] AI service exists and tested (12+ tests passing)
- [ ] Service builds correct user prompt from list_items
- [ ] Service updates list_item.metadata correctly
- [ ] Background job exists and tested (8+ tests passing)
- [ ] Job processes only items with mb_recording_id
- [ ] Job updates wizard_step_status with progress
- [ ] Job is idempotent
- [ ] View component renders all UI states
- [ ] Component tests pass (10+ tests)
- [ ] Controller handles validate step correctly
- [ ] Controller tests pass (5+ new tests)
- [ ] Polling updates progress in real-time
- [ ] Stats display correctly after completion
- [ ] Error messages display correctly
- [ ] Navigation flow works end-to-end
- [ ] All tests pass (35+ new tests total)
- [ ] No N+1 queries introduced
- [ ] Documentation updated

---

## Dependencies

### Depends On (Completed)
- ✅ [086] Infrastructure - wizard_state, routes, model helpers
- ✅ [087] Wizard UI Shell - WizardController, polling Stimulus controller
- ✅ [088] Step 0: Import Source - import_source selection
- ✅ [089] Step 1: Parse - Creates unverified list_items with metadata
- ✅ [090] Step 2: Enrich - Adds mb_recording_id to list_items
- ✅ [090a] Step-Namespaced Status - wizard_step_status methods

### Needed By (Blocked Until This Completes)
- [092] Step 4: Review UI - Displays validated items with Invalid badges
- [094] Step 5: Import - Skips items with ai_match_invalid flag

### External References
- **Existing Validator**: `app/lib/services/ai/tasks/lists/music/songs/items_json_validator_task.rb` (lines 1-116)
- **Base Task**: `app/lib/services/ai/tasks/base_task.rb`
- **Enrich Job Pattern**: `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb`
- **Enrich Component Pattern**: `app/components/admin/music/songs/wizard/enrich_step_component.rb`
- **ListItem Model**: `app/models/list_item.rb` (lines 1-70)
- **List Model**: `app/models/list.rb` (wizard_step_status methods)

---

## Related Tasks

- **Previous**: [090] Song Step 2: Enrich
- **Next**: [092] Song Step 4: Review UI
- **Reference**: Existing AI validator (adapt patterns, create new service)

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns (Sidekiq jobs, ViewComponents, polling)
- Do not duplicate authoritative code; **link to files by path**
- Respect snippet budget (≤40 lines per snippet)
- Create new `ListItemsValidatorTask` - do NOT modify existing `ItemsJsonValidatorTask`
- Update wizard_step_status atomically at all stages
- Make job idempotent (can retry safely)
- Use step-namespaced status pattern from 090a

### Required Outputs
- New file: `app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb`
- New file: `app/sidekiq/music/songs/wizard_validate_list_items_job.rb`
- New file: `test/lib/services/ai/tasks/lists/music/songs/list_items_validator_task_test.rb`
- New file: `test/sidekiq/music/songs/wizard_validate_list_items_job_test.rb`
- New file: `test/components/admin/music/songs/wizard/validate_step_component_test.rb`
- Modified: `app/components/admin/music/songs/wizard/validate_step_component.rb`
- Modified: `app/components/admin/music/songs/wizard/validate_step_component.html.erb`
- Modified: `app/controllers/admin/music/songs/list_wizard_controller.rb`
- Modified: `test/controllers/admin/music/songs/list_wizard_controller_test.rb`
- Passing tests for all new functionality (35+ tests)
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1. **codebase-pattern-finder** → Already done (collected validator patterns, enrich step patterns)
2. **codebase-analyzer** → Already done (verified data flow & integration points)
3. **technical-writer** → Update docs after implementation

### Test Fixtures
- Use existing `lists(:music_songs_list)` fixture
- Use existing `list_items` fixtures with programmatic metadata setup
- Mock AI service responses in tests (use `stubs`)

---

## Implementation Notes

### Files Created
- `app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb` - AI validation service
- `app/sidekiq/music/songs/wizard_validate_list_items_job.rb` - Background job for async validation
- `test/lib/services/ai/tasks/lists/music/songs/list_items_validator_task_test.rb` - 21 tests
- `test/sidekiq/music/songs/wizard_validate_list_items_job_test.rb` - 12 tests
- `test/components/admin/music/songs/wizard/validate_step_component_test.rb` - 17 tests

### Files Modified
- `app/components/admin/music/songs/wizard/validate_step_component.rb` - Full implementation with status helpers
- `app/components/admin/music/songs/wizard/validate_step_component.html.erb` - Full UI with 4 states
- `app/controllers/admin/music/songs/list_wizard_controller.rb` - Added validate step logic + fixed source step validation
- `test/controllers/admin/music/songs/list_wizard_controller_test.rb` - Added 5 validate step tests + fixed 2 source step tests

### Key Implementation Details
- Uses `gpt-5-mini` model (matching existing `ItemsJsonValidatorTask`)
- Single AI call batches all items for validation
- Progress: 0% → 100% (no incremental progress since single AI call)
- Validates both OpenSearch and MusicBrainz matches (unlike Avo workflow)
- Sets `verified = true` on valid matches
- Clears `listable_id` on invalid OpenSearch matches
- Job is idempotent - clears previous validation flags before re-running

### Test Coverage
- 50+ new tests for validation step functionality
- All tests passing

---

## Deviations from Plan

1. **Component preview scope**: Changed `enriched_items` to query ALL items (not just unverified) so that items marked as verified during validation still appear in the preview table.

2. **Job idempotency enhancement**: Extended `clear_previous_validation_flags` to also reset `verified = false` for previously verified items that will be re-validated.

3. **Fixed pre-existing source step tests**: The tests for source step validation were failing because:
   - Controller was defaulting to `"custom_html"` instead of validating
   - Tests were checking `flash[:alert]` but redirects encode flash in URL params
   - Added `VALID_IMPORT_SOURCES` constant and validation logic
   - Updated tests to check URL-encoded alert in `response.location`

---

## Documentation Updated

- [x] This task file updated with implementation notes
- [x] Cross-references updated in related task files
- [x] Service documentation created at `docs/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.md`
- [x] Job documentation created at `docs/sidekiq/music/songs/wizard_validate_list_items_job.md`

---

## Notes

### Key Differences from Avo Workflow

The existing `ItemsJsonValidatorTask` (used by Avo) only validates MusicBrainz matches. This wizard implementation improves on that by:

1. **Validating ALL enriched items** - Both OpenSearch and MusicBrainz matches
2. **Setting verified = true** - Gives users immediate confidence in AI-validated matches
3. **Clearing invalid OpenSearch matches** - Removes incorrect `listable_id` associations
4. **Including match source in prompt** - Helps AI understand context

This is intentionally different from the Avo workflow to provide a better user experience in the wizard.

### Performance Considerations
- Single AI call per validation run (batches all items)
- AI call typically takes 5-30 seconds depending on item count
- Polling interval of 2 seconds is sufficient

### Security Considerations
- Job runs in background worker (no direct user input in job)
- List ID validated by ActiveRecord (raises if not found)
- wizard_state updates use ActiveRecord (prevents SQL injection)
- AI responses parsed with structured schema

### Future Enhancements (Out of Scope)
- [ ] Per-item validation (streaming progress)
- [ ] Manual override of validation results
- [ ] Configurable validation criteria
- [ ] Multi-model validation (use multiple AI providers)
- [ ] Backport improvements to Avo workflow

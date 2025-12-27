# 090a: Wizard Step-Namespaced Status

**Status**: Completed
**Completed**: 2025-11-30
**Priority**: High
**Created**: 2025-11-30

## Problem Statement

The Songs List Wizard uses a single flat `wizard_state` JSONB structure for job status (`job_status`, `job_progress`, `job_error`, `job_metadata`). When navigating between steps:

1. **Status gets reset to "idle"** when advancing (e.g., parse → enrich), even though parse completed successfully
2. **Going back to a previous step** shows incorrect UI state (shows "Start Parsing" button instead of completed results)
3. **No isolation between steps** - all steps share the same status fields

### Current Behavior (Bug)
1. User completes parse step (status: "completed", metadata has `parsed_at`)
2. User clicks "Next" → controller resets status to "idle" at `list_wizard_controller.rb:160`
3. User clicks "Back" → parse step shows as "idle" with "Start Parsing" button
4. Parse results (list_items) still exist in DB, but UI doesn't reflect completion

### Desired Behavior
1. Each step maintains its own status/progress/metadata
2. Navigating back shows the step's last known state
3. Re-running a step explicitly resets only that step's state

---

## Solution: Step-Namespaced State

### New Data Structure

```ruby
wizard_state = {
  # Navigation (unchanged)
  "current_step" => 2,
  "started_at" => "2025-11-30T12:00:00Z",
  "completed_at" => nil,

  # Step-specific data (unchanged)
  "import_source" => "custom_html",

  # NEW: Per-step job state
  "steps" => {
    "parse" => {
      "status" => "completed",
      "progress" => 100,
      "error" => nil,
      "metadata" => {
        "total_items" => 50,
        "parsed_at" => "2025-11-30T12:05:00Z"
      }
    },
    "enrich" => {
      "status" => "completed",
      "progress" => 100,
      "error" => nil,
      "metadata" => {
        "processed_items" => 50,
        "total_items" => 50,
        "opensearch_matches" => 35,
        "musicbrainz_matches" => 10,
        "not_found" => 5,
        "enriched_at" => "2025-11-30T12:15:00Z"
      }
    },
    "validate" => {
      "status" => "idle",
      "progress" => 0,
      "error" => nil,
      "metadata" => {}
    }
  }
}
```

---

## Contracts

### Model Methods (List)

#### New Step-Aware Methods

| Method | Signature | Returns | Purpose |
|--------|-----------|---------|---------|
| `wizard_step_status` | `(step_name)` | String | Status for specific step ("idle", "running", "completed", "failed") |
| `wizard_step_progress` | `(step_name)` | Integer | Progress 0-100 for specific step |
| `wizard_step_error` | `(step_name)` | String/nil | Error message for specific step |
| `wizard_step_metadata` | `(step_name)` | Hash | Metadata hash for specific step |
| `update_wizard_step_status` | `(step:, status:, progress:, error:, metadata:)` | Boolean | Update status for specific step |
| `reset_wizard_step!` | `(step_name)` | Boolean | Reset a single step to idle state |

#### Backward Compatibility (Deprecated)

Existing methods remain for backward compatibility but are **deprecated**:
- `wizard_job_status` → delegates to current step
- `wizard_job_progress` → delegates to current step
- `wizard_job_error` → delegates to current step
- `wizard_job_metadata` → delegates to current step
- `update_wizard_job_status` → delegates to current step

### Controller Changes

| Location | Current Behavior | New Behavior |
|----------|------------------|--------------|
| `advance_from_parse_step` (completed branch) | Resets status to "idle" | Only updates `current_step`, preserves parse status |
| `advance_from_enrich_step` (completed branch) | Resets status to "idle" | Only updates `current_step`, preserves enrich status |
| `step_status` endpoint | Returns flat status | Returns step-specific status based on `params[:step]` |

### Job Changes

| Job | Current Call | New Call |
|-----|--------------|----------|
| `WizardParseListJob` | `update_wizard_job_status(status:, ...)` | `update_wizard_step_status(step: "parse", status:, ...)` |
| `WizardEnrichListItemsJob` | `update_wizard_job_status(status:, ...)` | `update_wizard_step_status(step: "enrich", status:, ...)` |

### Component Changes

| Component | Current Access | New Access |
|-----------|----------------|------------|
| `ParseStepComponent` | `list.wizard_job_status` | `list.wizard_step_status("parse")` |
| `EnrichStepComponent` | `list.wizard_job_status` | `list.wizard_step_status("enrich")` |
| `EnrichStepComponent` | `list.wizard_job_metadata` | `list.wizard_step_metadata("enrich")` |

---

## Acceptance Criteria

### AC1: Step status persists after navigation
```gherkin
Scenario: Parse status persists when navigating forward and back
  Given a list with completed parse step (50 items parsed)
  When I advance to the enrich step
  And I navigate back to the parse step
  Then parse step shows status "completed"
  And parse step shows "50 items parsed"
  And I see the parsed items table
  And I do NOT see "Start Parsing" button
```

### AC2: Enrich status persists after navigation
```gherkin
Scenario: Enrich status persists when navigating forward and back
  Given a list with completed enrich step (35 OpenSearch, 10 MusicBrainz, 5 not found)
  When I advance to the validate step
  And I navigate back to the enrich step
  Then enrich step shows status "completed"
  And enrich step shows correct match statistics
  And I do NOT see "Start Enrichment" button
```

### AC3: Re-running a step resets only that step
```gherkin
Scenario: Re-parse only resets parse step
  Given a list with completed parse and enrich steps
  When I navigate to parse step
  And I click "Re-parse HTML"
  Then parse step status is "idle"
  And enrich step status remains "completed"
```

### AC4: Step status endpoint returns step-specific data
```gherkin
Scenario: Status endpoint returns correct step data
  Given a list with parse=completed and enrich=running
  When I GET /admin/songs/lists/:id/wizard/step_status?step=parse
  Then response contains status="completed", progress=100
  When I GET /admin/songs/lists/:id/wizard/step_status?step=enrich
  Then response contains status="running", progress=50
```

### AC5: Backward compatibility maintained
```gherkin
Scenario: Deprecated methods still work
  Given existing code calls list.wizard_job_status
  Then it returns the current step's status
  And no errors are raised
```

---

## Key Files to Touch

### Model
- `app/models/list.rb` - Add step-aware methods, deprecate old methods

### Controller
- `app/controllers/concerns/wizard_controller.rb` - Update `step_status` action
- `app/controllers/admin/music/songs/list_wizard_controller.rb` - Remove status reset from advance methods

### Jobs
- `app/sidekiq/music/songs/wizard_parse_list_job.rb` - Use `update_wizard_step_status`
- `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb` - Use `update_wizard_step_status`

### Components
- `app/components/admin/music/songs/wizard/parse_step_component.rb` - Use step-specific status (if needed)
- `app/components/admin/music/songs/wizard/enrich_step_component.rb` - Use step-specific status

### Tests
- `test/models/list_test.rb` - Test new step-aware methods
- `test/controllers/admin/music/songs/list_wizard_controller_test.rb` - Test navigation preserves status
- `test/sidekiq/music/songs/wizard_parse_list_job_test.rb` - Test step-specific updates
- `test/sidekiq/music/songs/wizard_enrich_list_items_job_test.rb` - Test step-specific updates

---

## Implementation Notes

### Migration Strategy
- No database migration needed (JSONB column already exists)
- New structure lives alongside old keys
- Old code continues to work via deprecated method delegation

### Helper Method for Step State Access

```ruby
# reference only - app/models/list.rb
private

def wizard_steps_data
  safe_wizard_state.fetch("steps", {})
end

def wizard_step_data(step_name)
  wizard_steps_data.fetch(step_name.to_s, default_step_state)
end

def default_step_state
  { "status" => "idle", "progress" => 0, "error" => nil, "metadata" => {} }
end
```

### Determining "Current Step" for Deprecated Methods

The deprecated `wizard_job_*` methods need to know which step to delegate to. Use the step name from `current_step` index:

```ruby
# reference only
WIZARD_STEPS = %w[source parse enrich validate review import complete].freeze

def current_step_name
  WIZARD_STEPS[wizard_current_step] || "source"
end

def wizard_job_status
  ActiveSupport::Deprecation.warn("wizard_job_status is deprecated, use wizard_step_status(step)")
  wizard_step_status(current_step_name)
end
```

---

## Golden Examples

### Example 1: Reading Step Status
```ruby
# After parse completes and user advances to enrich
list.wizard_step_status("parse")    # => "completed"
list.wizard_step_status("enrich")   # => "idle"
list.wizard_step_metadata("parse")  # => {"total_items" => 50, "parsed_at" => "..."}
```

### Example 2: Job Updating Step Status
```ruby
# In WizardEnrichListItemsJob
@list.update_wizard_step_status(
  step: "enrich",
  status: "running",
  progress: 50,
  metadata: { "processed_items" => 25, "total_items" => 50 }
)
```

### Example 3: Controller Not Resetting Status
```ruby
# In advance_from_parse_step (completed branch) - BEFORE
wizard_entity.update_wizard_job_status(status: "idle", progress: 0, error: nil, metadata: {})

# AFTER - just advance the step, don't touch status
wizard_entity.update!(wizard_state: wizard_entity.wizard_state.merge("current_step" => next_step_index))
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture
- Respect snippet budget (≤40 lines per snippet)
- Do not duplicate authoritative code; link to files by path
- Maintain backward compatibility with deprecated methods

### Required Outputs
- Updated files (paths listed in "Key Files to Touch")
- Passing tests for all Acceptance Criteria
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1. **codebase-pattern-finder** → Already done (see research above)
2. **codebase-analyzer** → Already done (see research above)
3. **technical-writer** → Update docs after implementation

### Test Fixtures
Use existing `lists(:music_songs_list)` fixture with programmatic setup:
```ruby
@list.update!(wizard_state: {
  "current_step" => 2,
  "steps" => {
    "parse" => { "status" => "completed", "progress" => 100, "metadata" => {"total_items" => 50} },
    "enrich" => { "status" => "idle", "progress" => 0, "metadata" => {} }
  }
})
```

---

## Deviations

1. **Turbo Frame refresh issue** - When a job completes, the Stimulus controller was only refreshing the turbo frame content, but the navigation component is outside the frame. Changed `wizard_step_controller.js` to do a full `Turbo.visit()` instead of just setting `frame.src` to ensure the navigation buttons update correctly.

2. **Source step import_source handling** - Updated `advance_from_source_step` to fall back to existing `import_source` in wizard_state or default to "custom_html" if not provided. This fixes navigation issues when clicking Next without explicitly selecting an import source.

3. **Restart button styling** - Changed from `btn-ghost btn-sm` to `btn-outline` for better visibility, matching the Back button style.

---

## Documentation Updated

- [x] Class documentation for List model (new methods) - inline code comments
- [ ] This task file moved to `completed/` when done
- [x] `todo.md` updated

---

## Acceptance Results

### AC1: Step status persists after navigation ✅
- Parse status is preserved when advancing to enrich step
- Navigating back to parse step shows "completed" status with parsed items
- "Start Parsing" button is NOT shown when parse is completed

### AC2: Enrich status persists after navigation ✅
- Enrich status is preserved when advancing to validate step
- Navigating back to enrich step shows "completed" status with match statistics
- "Start Enrichment" button is NOT shown when enrich is completed

### AC3: Re-running a step resets only that step ✅
- `reset_wizard_step!("parse")` resets only parse step
- Enrich step status remains unchanged
- Controller uses this method in reparse action

### AC4: Step status endpoint returns step-specific data ✅
- `step_status` action accepts `step` parameter
- Returns step-specific status, progress, error, and metadata
- Falls back to current step if no parameter provided

### AC5: Backward compatibility maintained ✅
- Legacy methods (`wizard_job_status`, `wizard_job_progress`, etc.) still work
- They delegate to current step based on `current_step_name`
- No errors raised, all existing tests pass

---

## Implementation Summary

### Files Modified
1. **app/models/list.rb** - Added step-namespaced methods:
   - `WIZARD_STEPS` constant
   - `current_step_name` method
   - `wizard_step_status(step_name)`, `wizard_step_progress(step_name)`, `wizard_step_error(step_name)`, `wizard_step_metadata(step_name)`
   - `update_wizard_step_status(step:, status:, progress:, error:, metadata:)`
   - `reset_wizard_step!(step_name)`
   - Updated `reset_wizard!` to use `steps` instead of flat structure
   - Legacy methods now delegate to current step
   - Private helpers: `wizard_steps_data`, `wizard_step_data`, `default_step_state`

2. **app/controllers/concerns/wizard_controller.rb** - Updated `step_status` action to accept step parameter

3. **app/controllers/admin/music/songs/list_wizard_controller.rb** - Updated to:
   - Use `wizard_step_status("parse")` and `wizard_step_status("enrich")`
   - Use `update_wizard_step_status(step:...)` instead of `update_wizard_job_status`
   - Remove status reset when advancing between steps (KEY FIX)
   - Use `reset_wizard_step!("parse")` in reparse action
   - Updated `advance_from_source_step` to default to "custom_html" if no import_source provided

4. **app/sidekiq/music/songs/wizard_parse_list_job.rb** - Use `update_wizard_step_status(step: "parse", ...)`

5. **app/sidekiq/music/songs/wizard_enrich_list_items_job.rb** - Use `update_wizard_step_status(step: "enrich", ...)`

6. **app/components/admin/music/songs/wizard/parse_step_component.html.erb** - Use step-specific status

7. **app/components/admin/music/songs/wizard/enrich_step_component.rb** - Added step-specific helper methods

8. **app/components/admin/music/songs/wizard/enrich_step_component.html.erb** - Use step-specific status

9. **app/javascript/controllers/wizard_step_controller.js** - Changed `refreshWizardContent()` to use `Turbo.visit()` instead of frame refresh

10. **app/components/wizard/navigation_component.html.erb** - Updated Restart button to use `btn-outline` styling

### Tests Updated
- `test/models/list_test.rb` - Added 19 new tests for step-namespaced methods
- `test/controllers/admin/music/songs/list_wizard_controller_test.rb` - Updated to use step-namespaced structure
- `test/sidekiq/music/songs/wizard_enrich_list_items_job_test.rb` - Updated stub method name
- `test/components/admin/music/songs/wizard/parse_step_component_test.rb` - Updated to use step-namespaced structure
- `test/components/admin/music/songs/wizard/enrich_step_component_test.rb` - Updated to use step-namespaced structure
- `test/components/wizard/navigation_component_test.rb` - Updated to use step-namespaced structure

### Test Results
All 2323 tests pass with 0 failures, 0 errors.

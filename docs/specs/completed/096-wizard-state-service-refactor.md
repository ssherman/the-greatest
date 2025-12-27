# 096 - Extract Wizard State Management to Service Object

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-12-26
- **Started**: 2025-12-26
- **Completed**: 2025-12-26
- **Developer**: Claude Opus 4.5

## Overview

Extract all wizard-related methods from the `List` model into a dedicated service object hierarchy. This refactoring follows the "skinny models, fat services" principle by moving UI/workflow-specific logic out of the base model. The new service will provide a base class for generic wizard state management with domain-specific subclasses that define step configurations.

**Goals**:
- Remove ~100 lines of wizard-specific code from List model
- Create reusable WizardStateManager base class
- Enable easy wizard implementation for new list types (albums, movies, books, games)

**Non-Goals**:
- Changing the wizard_state JSONB schema
- Adding new wizard functionality

**Cleanup**:
- Remove "legacy" methods that are unused or easily replaced with step-specific calls

## Context & Links

- Related: [List Wizard Feature](/docs/features/list-wizard.md)
- Authoritative source files:
  - `app/models/list.rb` (lines 109-225 to be extracted)
  - `app/controllers/concerns/wizard_controller.rb`
  - `app/sidekiq/music/songs/wizard_*.rb` (4 jobs)
  - `app/components/admin/music/songs/wizard/*.rb`
  - `app/helpers/admin/music/songs/list_wizard_helper.rb`
- External docs: None required

## Interfaces & Contracts

### Domain Model Changes

**List model** - Remove wizard methods, retain only:
- `wizard_state` column (unchanged)
- Possibly a thin delegation method for convenience

**No new migrations required** - wizard_state column already exists.

### New Service Class Hierarchy

```
app/lib/services/lists/wizard/
  state_manager.rb          # Base class
  music/
    songs/
      state_manager.rb      # Song-specific steps
    albums/
      state_manager.rb      # Album-specific steps (future)
```

Follows existing `Services::Lists::*` namespace pattern (see `Services::Lists::ImportService`).

### Services::Lists::Wizard::StateManager Interface

| Method | Parameters | Returns | Purpose |
|--------|------------|---------|---------|
| `.new(list)` | List instance | StateManager | Constructor |
| `.for(list)` | List instance | StateManager subclass | Factory method |
| `#current_step` | - | Integer | Current step index |
| `#current_step_name` | - | String | Current step name |
| `#step_status(step_name)` | String | String | Step status (idle/running/completed/failed) |
| `#step_progress(step_name)` | String | Integer (0-100) | Step progress percentage |
| `#step_error(step_name)` | String | String/nil | Error message if failed |
| `#step_metadata(step_name)` | String | Hash | Step-specific metadata |
| `#update_step_status!(...)` | step:, status:, progress:, error:, metadata: | Boolean | Update step state |
| `#reset_step!(step_name)` | String | Boolean | Reset single step |
| `#reset!` | - | Boolean | Full wizard reset |
| `#in_progress?` | - | Boolean | Check if wizard active |

### Subclass Contract

Domain-specific subclasses must implement:

| Method | Returns | Purpose |
|--------|---------|---------|
| `#steps` | Array<String> | Ordered step names for this wizard type |

### Factory Method Behavior

```ruby
# Returns appropriate subclass based on list type
Services::Lists::Wizard::StateManager.for(music_songs_list)
# => Services::Lists::Wizard::Music::Songs::StateManager instance

Services::Lists::Wizard::StateManager.for(music_albums_list)
# => Services::Lists::Wizard::Music::Albums::StateManager instance

Services::Lists::Wizard::StateManager.for(unknown_type_list)
# => Services::Lists::Wizard::StateManager instance (base class fallback)
```

### Schemas (JSON)

wizard_state schema unchanged:
```json
{
  "type": "object",
  "properties": {
    "current_step": { "type": "integer" },
    "started_at": { "type": "string", "format": "date-time" },
    "completed_at": { "type": ["string", "null"], "format": "date-time" },
    "import_source": { "type": "string" },
    "steps": {
      "type": "object",
      "additionalProperties": {
        "type": "object",
        "properties": {
          "status": { "enum": ["idle", "running", "completed", "failed"] },
          "progress": { "type": "integer", "minimum": 0, "maximum": 100 },
          "error": { "type": ["string", "null"] },
          "metadata": { "type": "object" }
        }
      }
    }
  }
}
```

### Behaviors (pre/postconditions)

**Preconditions**:
- List must have `wizard_state` column (all List subclasses do)
- List must be persisted (has id)

**Postconditions**:
- All state updates persist to database immediately via `update!`
- Step updates merge metadata (don't replace)
- Reset operations clear to known initial state

**Edge cases**:
- `nil` wizard_state treated as empty hash `{}`
- Unknown step names return default state `{status: "idle", progress: 0, error: nil, metadata: {}}`
- Factory returns base class for unregistered list types

### Legacy Method Removal

The following methods in `List` model (lines 165-198) are marked "deprecated" but this is a new feature—no deprecation needed. Analysis shows all callers have step names available:

| Method | Production Callers | Action |
|--------|-------------------|--------|
| `wizard_job_status` | 3 callers (all have step_name) | **Remove** |
| `wizard_job_progress` | 0 production callers | **Remove** |
| `wizard_job_error` | 0 production callers | **Remove** |
| `wizard_job_metadata` | 1 caller (helper, has step context) | **Remove** |
| `update_wizard_job_status` | 0 production callers | **Remove** |

**Caller updates required:**

1. `app/helpers/admin/music/songs/list_wizard_helper.rb:49`:
   ```ruby
   # Before
   list.wizard_job_status != "running"
   # After
   list.wizard_step_status(step_name) != "running"
   ```

2. `app/helpers/admin/music/songs/list_wizard_helper.rb:70-73`:
   ```ruby
   # Before
   case list.wizard_job_status
   # After - pass step_name to method or make step-aware
   def job_status_text(list, step_name)
     case list.wizard_step_status(step_name)
   ```

3. `app/components/wizard/navigation_component.rb:23`:
   ```ruby
   # Before
   @list.wizard_job_status == "running"
   # After
   @list.wizard_step_status(@step_name) == "running"
   ```

**Test updates:** Remove tests for legacy methods in `test/models/list_test.rb` (lines 190-373 testing wizard_job_* methods).

### Non-Functionals

- **Performance**: No additional queries; reads/writes same as current implementation
- **No backward compatibility needed**: This is a new feature; remove unused abstractions
- **Security/roles**: No changes to authorization (admin-only access unchanged)

## Acceptance Criteria

- [ ] `List` model has no wizard-specific methods (except optional thin delegation)
- [ ] Legacy `wizard_job_*` methods removed from List model entirely
- [ ] `Services::Lists::Wizard::StateManager` base class implements all methods
- [ ] `Services::Lists::Wizard::Music::Songs::StateManager` subclass with `STEPS = %w[source parse enrich validate review import complete]`
- [ ] Factory method `.for(list)` returns correct subclass based on list type
- [ ] All 4 wizard jobs updated to use new service
- [ ] `WizardController` concern updated to use new service
- [ ] `Wizard::NavigationComponent` updated to use step-specific method
- [ ] `ListWizardHelper` updated to use step-specific methods
- [ ] Legacy method tests removed from `list_test.rb`
- [ ] All existing wizard functionality tests pass
- [ ] New unit tests for StateManager base class and factory

### Golden Examples

**Input**: Create manager and update step status
```ruby
list = Music::Songs::List.find(123)
manager = Services::Lists::Wizard::StateManager.for(list)

manager.current_step_name # => "parse"
manager.step_status("parse") # => "idle"

manager.update_step_status!(
  step: "parse",
  status: "running",
  progress: 0,
  metadata: { total_items: 50 }
)

manager.step_status("parse") # => "running"
list.reload.wizard_state["steps"]["parse"]["status"] # => "running"
```

**Input**: Factory returns correct subclass
```ruby
song_list = Music::Songs::List.find(1)
album_list = Music::Albums::List.find(2)

Services::Lists::Wizard::StateManager.for(song_list).class.name
# => "Services::Wizard::Music::Songs::StateManager"

Services::Lists::Wizard::StateManager.for(album_list).class.name
# => "Services::Lists::Wizard::StateManager" (base until album wizard implemented)
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- Use service pattern from `app/lib/services/` (see `lists/import_service.rb` for model-in-initializer pattern).
- Use Result pattern with Struct if returning success/failure, but for this service simple boolean returns are sufficient since state is persisted.

### Required Outputs
- New service files in `app/lib/services/wizard/`
- Updated callers (jobs, controllers, components, helpers)
- Unit tests for StateManager
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) **codebase-pattern-finder** → Verify service patterns (already done in research)
2) **codebase-analyzer** → Trace all callers to update (already done in research)
3) **technical-writer** → Update docs/features/list-wizard.md after implementation

### Test Seed / Fixtures
- Use existing `lists.yml` fixtures (music_songs_list types exist)
- No new fixtures required

### Caller Update Guide

**Sidekiq Jobs** (4 files):
```ruby
# Before
@list.update_wizard_step_status(step: "enrich", status: "running", ...)

# After
@manager = Services::Lists::Wizard::StateManager.for(@list)
@manager.update_step_status!(step: "enrich", status: "running", ...)
```

**WizardController Concern**:
```ruby
# Before
wizard_entity.wizard_step_status(step_name)

# After
wizard_state_manager.step_status(step_name)

# Add helper method
def wizard_state_manager
  @wizard_state_manager ||= Services::Lists::Wizard::StateManager.for(wizard_entity)
end
```

**NavigationComponent** (uses step_name it already has):
```ruby
# Before
@list.wizard_job_status == "running"

# After (use @step_name which component already receives)
Services::Lists::Wizard::StateManager.for(@list).step_status(@step_name) == "running"
```

**ListWizardHelper**:
```ruby
# Before
list.wizard_job_status != "running"

# After (method already receives step_name)
Services::Lists::Wizard::StateManager.for(list).step_status(step_name) != "running"
```

**Optional thin delegation** - If many callers, add to List for convenience:
```ruby
# In List model
def wizard_manager
  @wizard_manager ||= Services::Lists::Wizard::StateManager.for(self)
end
```

---

## Implementation Notes (living)
- **Approach taken**: Created base `Services::Lists::Wizard::StateManager` class with factory method `.for(list)` that returns the appropriate subclass based on list type. All wizard methods moved from List model to the service, with a thin `wizard_manager` delegation method retained on List.
- **Important decisions**:
  - Used factory pattern rather than direct instantiation to enable easy addition of new wizard types
  - All state updates use `update!` for immediate persistence (matches original behavior)
  - Metadata is merged, not replaced, when updating step status (matches original behavior)
  - Memoized the `wizard_manager` method on List to avoid repeated service instantiation

### Key Files Touched (paths only)
- `app/lib/services/lists/wizard/state_manager.rb` (new)
- `app/lib/services/lists/wizard/music/songs/state_manager.rb` (new)
- `app/models/list.rb` (remove wizard methods, add thin delegation)
- `app/controllers/concerns/wizard_controller.rb`
- `app/sidekiq/music/songs/wizard_parse_list_job.rb`
- `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb`
- `app/sidekiq/music/songs/wizard_validate_list_items_job.rb`
- `app/sidekiq/music/songs/wizard_import_songs_job.rb`
- `app/helpers/admin/music/songs/list_wizard_helper.rb`
- `app/components/wizard/navigation_component.rb`
- `test/models/list_test.rb` (remove legacy method tests)
- `test/lib/services/lists/wizard/state_manager_test.rb` (new)

### Challenges & Resolutions
- **Many callers to update**: The wizard methods were used extensively in step components, controller, helper, and tests. Used global replace_all for test files and individual edits for source files.
- **Step components**: Each step component (parse, enrich, validate, import) had its own methods calling wizard_step_* - updated all to use wizard_manager

### Deviations From Plan
- None - implementation followed the spec exactly

## Acceptance Results
- **Date**: 2025-12-26
- **Verifier**: Claude Opus 4.5
- **Result**: All 2505 tests pass (0 failures, 0 errors)
- **Artifacts**: Test run output shows full suite passing

## Future Improvements
- Create `Services::Wizard::Music::Albums::StateManager` when album wizard is needed
- Consider extracting step configuration to YAML or database for more flexibility
- Could add step validation (ensure valid step names)

## Related PRs
-

## Documentation Updated
- [x] `docs/features/list-wizard.md` - Note: feature doc still accurate, references List model which now delegates to service
- [x] Class docs for new service - Inline documentation in state_manager.rb

## Design Decisions

### 1. Remove Legacy Methods Entirely
The `wizard_job_*` methods were labeled "deprecated" but this is a new feature with only 3 production callers. All callers have access to step names, so these convenience methods add complexity without benefit. **Remove them.**

### 2. Thin Delegation for Convenience
Keep a single `wizard_manager` method on List that returns the StateManager:

```ruby
# In List model - ONLY this remains
def wizard_manager
  @wizard_manager ||= Services::Lists::Wizard::StateManager.for(self)
end
```

This provides:
- Clean separation (all logic in service)
- Convenient access from views/components (`@list.wizard_manager.step_status(...)`)
- No method proliferation on the model

### 3. Factory Pattern for Subclass Selection
Use `.for(list)` factory method to return appropriate subclass based on list type. This makes adding new wizard types (albums, books, etc.) trivial—just create the subclass and register it.

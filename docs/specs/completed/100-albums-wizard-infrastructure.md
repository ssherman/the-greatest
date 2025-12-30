# 100 - Albums Wizard Infrastructure & Routes

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-12-27
- **Started**: 2025-12-28
- **Completed**: 2025-12-28
- **Developer**: Claude

## Overview
Set up the foundational infrastructure for the Music Albums List Wizard, including routes, controller, state manager, and helper module. This spec establishes the multi-step wizard framework that subsequent specs will build upon.

**Goal**: Enable navigation through wizard steps with proper state management.
**Scope**: Routes, controller shell, state manager, helper module, source step.
**Non-goals**: Background job implementation (handled in subsequent specs).

## Context & Links
- Related specs: 101-albums-wizard-parse, 102-albums-wizard-enrich, 103-albums-wizard-validate, 104-albums-wizard-review, 105-albums-wizard-import
- Songs wizard reference: `app/controllers/admin/music/songs/list_wizard_controller.rb`
- WizardController concern: `app/controllers/concerns/wizard_controller.rb`
- StateManager base: `app/lib/services/lists/wizard/state_manager.rb`

## Interfaces & Contracts

### Routes
Routes nested under `Admin::Music::Albums::Lists`:

| Verb | Path | Action | Purpose |
|------|------|--------|---------|
| GET | `/admin/music/albums/lists/:list_id/wizard` | show | Redirect to current step |
| GET | `/admin/music/albums/lists/:list_id/wizard/step/:step` | show_step | Render specific step |
| GET | `/admin/music/albums/lists/:list_id/wizard/step/:step/status` | step_status | JSON status for polling |
| POST | `/admin/music/albums/lists/:list_id/wizard/step/:step/advance` | advance_step | Move to next step |
| POST | `/admin/music/albums/lists/:list_id/wizard/step/:step/back` | back_step | Move to previous step |
| POST | `/admin/music/albums/lists/:list_id/wizard/restart` | restart | Reset wizard |
| POST | `/admin/music/albums/lists/:list_id/wizard/save_html` | save_html | Save raw HTML input |
| POST | `/admin/music/albums/lists/:list_id/wizard/reparse` | reparse | Re-trigger parse |

> Source of truth: `config/routes.rb`

### Controller: Admin::Music::Albums::ListWizardController

```ruby
# app/controllers/admin/music/albums/list_wizard_controller.rb
class Admin::Music::Albums::ListWizardController < Admin::Music::BaseController
  include WizardController

  STEPS = %w[source parse enrich validate review import complete].freeze

  JOB_STEP_CONFIG = {
    "parse" => { job_class: "Music::Albums::WizardParseListJob", action_name: "Parsing", re_run_param: nil },
    "enrich" => { job_class: "Music::Albums::WizardEnrichListItemsJob", action_name: "Enrichment", re_run_param: :reenrich },
    "validate" => { job_class: "Music::Albums::WizardValidateListItemsJob", action_name: "Validation", re_run_param: :revalidate },
    "import" => { job_class: "Music::Albums::WizardImportAlbumsJob", action_name: "Import", re_run_param: nil, set_completed_on_advance: true }
  }.freeze
end
```

### StateManager: Services::Lists::Wizard::Music::Albums::StateManager

Subclass of base StateManager with albums-specific steps.

```ruby
# app/lib/services/lists/wizard/music/albums/state_manager.rb
module Services::Lists::Wizard::Music::Albums
  class StateManager < Services::Lists::Wizard::StateManager
    STEPS = %w[source parse enrich validate review import complete].freeze
    def steps = STEPS
  end
end
```

Update factory method in base class to return albums state manager:
```ruby
# In app/lib/services/lists/wizard/state_manager.rb, update self.for:
when "Music::Albums::List"
  Services::Lists::Wizard::Music::Albums::StateManager
```

### Helper Module

```ruby
# app/helpers/admin/music/albums/list_wizard_helper.rb
module Admin::Music::Albums::ListWizardHelper
  def render_step_component(step_name, list)
    # Dispatch to appropriate step component
  end

  def step_ready_to_advance?(step_name, list)
    # Return boolean based on step state
  end

  def next_button_label(step_name)
    # Return step-specific button label
  end
end
```

### Step Component: SourceStepComponent

```ruby
# app/components/admin/music/albums/wizard/source_step_component.rb
class Admin::Music::Albums::Wizard::SourceStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  def musicbrainz_available?
    @list.musicbrainz_series_id.present?
  end

  def default_import_source
    wizard_state_source || (musicbrainz_available? ? "musicbrainz_series" : "custom_html")
  end
end
```

### Behaviors (pre/postconditions)

**Preconditions:**
- User must have admin access
- `Music::Albums::List` record must exist
- List must have `wizard_state` JSONB column (already exists on base List)

**Postconditions:**
- Navigating to `/wizard` redirects to current step based on `wizard_state.current_step`
- Source selection saves `import_source` to `wizard_state`
- Step advancement updates `wizard_state.current_step`

**Edge cases:**
- Invalid step name returns 404
- Attempting to advance beyond "complete" is a no-op
- Back from "source" step is a no-op

### Non-Functionals
- No N+1 queries on wizard pages
- Page load < 200ms for all wizard steps
- Admin role required for all actions

## Acceptance Criteria
- [x] Routes are defined and accessible
- [x] ListWizardController includes WizardController concern
- [x] Source step renders with custom_html and musicbrainz_series options
- [x] MusicBrainz option only enabled when `musicbrainz_series_id` present
- [x] Selecting source and clicking "Next" advances to parse step
- [x] StateManager correctly returns albums steps
- [x] Helper module provides step component rendering
- [x] Navigation component shows correct step progress
- [x] Back/restart buttons work correctly
- [x] Existing wizard_step_controller.js Stimulus controller works (no JS changes needed)

### Golden Examples

**wizard_state after source selection:**
```json
{
  "current_step": 1,
  "started_at": "2025-12-27T10:00:00Z",
  "import_source": "custom_html",
  "steps": {
    "source": {
      "status": "completed",
      "progress": 100
    }
  }
}
```

---

## Agent Hand-Off

### Constraints
- Follow existing songs wizard patterns exactly
- Use generators for controller, components
- Reuse existing generic wizard components from `app/components/wizard/`
- Do not introduce new architectural patterns

### Required Outputs
- `app/controllers/admin/music/albums/list_wizard_controller.rb`
- `app/lib/services/lists/wizard/music/albums/state_manager.rb`
- `app/helpers/admin/music/albums/list_wizard_helper.rb`
- `app/components/admin/music/albums/wizard/source_step_component.rb`
- `app/components/admin/music/albums/wizard/source_step_component.html.erb`
- `app/views/admin/music/albums/list_wizard/show_step.html.erb`
- Route updates in `config/routes.rb`
- Test files for all new classes

### Sub-Agent Plan
1) codebase-pattern-finder → Review songs wizard controller pattern
2) codebase-analyzer → Verify route structure matches songs
3) technical-writer → Update documentation after implementation

### Test Seed / Fixtures
- Use existing `music/albums/lists.yml` fixtures
- Create basic list with `musicbrainz_series_id` for MusicBrainz path testing
- Create basic list without `musicbrainz_series_id` for custom HTML path testing

---

## Implementation Notes (living)
- Approach taken: Followed songs wizard patterns exactly as specified
- Important decisions: Used Rails generators for controller and component to ensure test files were created automatically

### Key Files Touched (paths only)
- `config/routes.rb`
- `app/controllers/admin/music/albums/list_wizard_controller.rb`
- `app/lib/services/lists/wizard/state_manager.rb` (update factory)
- `app/lib/services/lists/wizard/music/albums/state_manager.rb`
- `app/helpers/admin/music/albums/list_wizard_helper.rb`
- `app/components/admin/music/albums/wizard/source_step_component.rb`
- `app/components/admin/music/albums/wizard/source_step_component.html.erb`
- `app/views/admin/music/albums/list_wizard/show_step.html.erb`
- `test/controllers/admin/music/albums/list_wizard_controller_test.rb`
- `test/components/admin/music/albums/wizard/source_step_component_test.rb`
- `test/lib/services/lists/wizard/music/albums/state_manager_test.rb`
- `docs/features/list-wizard.md` (updated)

### Challenges & Resolutions
- None encountered - songs wizard provided clear patterns

### Deviations From Plan
- None

## Acceptance Results
- Date: 2025-12-28
- Verifier: Claude
- All 30 tests pass

## Future Improvements
- Consider extracting shared step logic between songs and albums wizards

## Related PRs
-

## Documentation Updated
- [x] `docs/features/list-wizard.md` - Add albums wizard section
- [ ] Class docs for new files (to be added as subsequent specs are implemented)

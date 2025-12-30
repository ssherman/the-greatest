# 106 - Wizard Shared Base Classes Refactoring

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-12-27
- **Started**: 2025-12-29
- **Completed**: 2025-12-29
- **Developer**: Claude

## Overview

Extract shared code between Music::Songs and Music::Albums wizard implementations into base classes and concerns. Analysis shows **85-95% code duplication** across controllers, components, jobs, and services. This refactoring reduces ~2,500 lines of duplicate code and establishes patterns for future media type wizards (books, movies, games).

**Goal**: DRY up wizard implementations without breaking existing functionality.
**Scope**: Base controllers, base components, base jobs, shared concerns.
**Non-goals**: Changing wizard behavior, adding features, or modifying the generic `Wizard::*` components.

## Context & Links

- **Prerequisite**: specs 100-105 (albums wizard) completed ✓
- **Generic wizard infrastructure**: `app/components/wizard/` (ContainerComponent, StepComponent, etc.) - NOT touched
- **Songs wizard**: `app/controllers/admin/music/songs/list_wizard_controller.rb`
- **Albums wizard**: `app/controllers/admin/music/albums/list_wizard_controller.rb`
- **Existing pattern**: `WizardController` concern at `app/controllers/concerns/wizard_controller.rb`

## Duplication Analysis Summary

### Controllers

| File Pair | Songs Lines | Albums Lines | Duplication |
|-----------|-------------|--------------|-------------|
| ListWizardController | 326 | 326 | **89%** |
| ListItemsActionsController | 383 | 472 | **70%** |

### ViewComponents

| Component | Ruby Duplication | ERB Duplication |
|-----------|------------------|-----------------|
| SourceStepComponent | 100% | 92% |
| ParseStepComponent | 100% | 93% |
| EnrichStepComponent | 100% | 96% |
| ValidateStepComponent | 95% | 94% |
| ReviewStepComponent | 75% | 70% |
| ImportStepComponent | 95% | 95% |
| CompleteStepComponent | 24% | 50% |
| SharedModalComponent | **100%** | **100%** |

### Background Jobs

| Job | Duplication |
|-----|-------------|
| WizardParseListJob | 92% |
| WizardEnrichListItemsJob | 95% |
| WizardValidateListItemsJob | 93% |
| WizardImportJob | 80% |

### Services

| Service | Duplication |
|---------|-------------|
| ListItemEnricher | 95% |
| StateManager | 100% |
| AI Validator Tasks | 85-90% |

---

## Interfaces & Contracts

### 1. Base ListWizardController

**Path**: `app/controllers/admin/music/base_list_wizard_controller.rb`

Extract 89% of shared code from both ListWizardControllers.

#### Abstract Methods (subclasses MUST implement)

| Method | Returns | Purpose |
|--------|---------|---------|
| `list_class` | Class | `Music::Songs::List` or `Music::Albums::List` |
| `enrichment_id_key` | String | `"mb_recording_id"` or `"mb_release_group_id"` |
| `entity_id_key` | String | `"song_id"` or `"album_id"` |
| `job_class_for(step_name)` | Class | Returns appropriate job class for step |
| `component_namespace` | Module | `Admin::Music::Songs::Wizard` or `Admin::Music::Albums::Wizard` |

#### Shared Methods (moved to base)

```ruby
# All of these are identical between songs/albums (reference only, ≤40 lines)
def advance_step           # 17 lines - step advancement dispatcher
def wizard_steps           # 3 lines - returns STEPS constant
def wizard_entity          # 3 lines - returns @list
def load_step_data         # 18 lines - dispatches to step-specific loaders
def should_enqueue_job?    # 3 lines - checks job steps
def enqueue_step_job       # 12 lines - dispatches to enqueue methods
def advance_from_job_step  # 22 lines - handles job step advancement
def start_job              # 4 lines - enqueues and updates status
def navigate_to_next_step  # 14 lines - step navigation
def advance_from_source_step    # 18 lines
def advance_from_parse_step     # 3 lines
def advance_from_enrich_step    # 3 lines
def advance_from_validate_step  # 3 lines
def advance_from_review_step    # 11 lines
def advance_from_import_step    # 3 lines
def save_html              # 4 lines
def reparse                # 5 lines
```

### 2. ListItemsActions Concern

**Path**: `app/controllers/concerns/list_items_actions.rb`

Extract shared actions from both ListItemsActionsControllers.

#### Shared Actions

| Action | Lines | Notes |
|--------|-------|-------|
| `modal` | 12 | Generic modal loading - subclass provides partial path |
| `verify` | 18 | Identical between songs/albums |
| `metadata` | 32 | Identical JSON parsing and update |
| `link_musicbrainz_artist` | 66 | Same logic, different metadata keys |
| `musicbrainz_artist_search` | 17 | 100% identical |
| `format_artist_display` | 21 | 100% identical (private helper) |

#### Abstract Methods

| Method | Returns | Purpose |
|--------|---------|---------|
| `list_class` | Class | Model class for list |
| `item_class` | Class | Model class for list item |
| `valid_modal_types` | Array | Valid modal type strings |
| `partials_path` | String | Path prefix for partials |
| `enrichment_keys_to_clear` | Array | Metadata keys to clear on re-enrich |
| `shared_modal_component_class` | Class | Component for error ID reference |

### 3. Shared Modal Component (Consolidate)

**Path**: `app/components/admin/music/wizard/shared_modal_component.rb`

Move from domain-specific to shared namespace. Both are 100% identical.

```ruby
# reference only
class Admin::Music::Wizard::SharedModalComponent < ViewComponent::Base
  DIALOG_ID = "shared_modal_dialog"
  FRAME_ID = "shared_modal_content"
  ERROR_ID = "shared_modal_error"

  def dialog_id = DIALOG_ID
  def frame_id = FRAME_ID
  def error_id = ERROR_ID
end
```

### 4. Base Step Components

Despite general recommendations against ViewComponent inheritance, the 85-95% duplication justifies base classes. Create base components that subclasses customize via:
1. Override methods for entity-specific values
2. Override templates only when significantly different

**Path**: `app/components/admin/music/wizard/base_*_component.rb`

#### Base Components to Create

| Base Component | Subclass Overrides |
|----------------|-------------------|
| `BaseSourceStepComponent` | `advance_path`, description text |
| `BaseParseStepComponent` | `save_html_path`, `step_status_path`, description text |
| `BaseEnrichStepComponent` | `step_status_path`, `advance_path`, description text |
| `BaseValidateStepComponent` | `enrichment_id_key`, `entity_id_key`, description text |
| `BaseReviewStepComponent` | `matched_title_key`, `entity_name_key`, path helpers |
| `BaseImportStepComponent` | `enrichment_id_key`, path helpers, entity terminology |

#### Template Strategy

For components with >90% ERB duplication:
- Base component provides the template
- Subclasses only override path helper methods
- Use `content_for` blocks for entity-specific text

For components with <80% duplication (Review, Complete):
- Base component provides shared Ruby methods only
- Subclasses provide their own templates

### 5. Base Background Jobs

**Path**: `app/sidekiq/music/base_wizard_*.rb`

#### BaseWizardParseListJob

```ruby
# reference only
class Music::BaseWizardParseListJob
  include Sidekiq::Job

  def perform(list_id)
    @list = find_list(list_id)
    validate_raw_html!
    update_status_running
    destroy_unverified_items
    parsed_items = call_parser_task
    create_list_items(parsed_items)
    update_status_completed
  rescue => e
    handle_error(e.message)
    raise
  end

  protected

  def find_list(list_id)         = raise NotImplementedError
  def parser_task_class          = raise NotImplementedError
  def listable_type              = raise NotImplementedError
  def data_key                   = raise NotImplementedError  # :songs or :albums
  def build_metadata(item)       = raise NotImplementedError
end
```

#### BaseWizardEnrichListItemsJob

| Shared Method | Lines | Notes |
|---------------|-------|-------|
| `perform` | 37 | Main job logic |
| `should_update_progress?` | 6 | 100% identical |
| `update_progress` | 19 | 100% identical |
| `complete_job` | 18 | 100% identical |
| `handle_error` | 8 | 100% identical |

| Abstract Method | Purpose |
|-----------------|---------|
| `find_list` | Load list by ID |
| `enricher_class` | Service class for enrichment |
| `enrichment_keys` | Array of metadata keys to clear |

#### BaseWizardValidateListItemsJob

| Shared Method | Lines | Notes |
|---------------|-------|-------|
| `perform` | 28 | Main job logic |
| `clear_previous_validation_flags` | 19 | Identical structure |
| `complete_with_no_items` | 17 | 100% identical |
| `complete_job` | 18 | 100% identical |
| `handle_error` | 8 | 100% identical |

| Abstract Method | Purpose |
|-----------------|---------|
| `find_list` | Load list by ID |
| `validator_task_class` | AI task class |
| `has_enrichment?(item)` | Check if item has enrichment data |

#### BaseWizardImportJob

| Shared Method | Lines | Notes |
|---------------|-------|-------|
| `import_from_custom_html` | 27 | Main import logic |
| `should_update_progress?` | 6 | 100% identical |
| `update_progress` | 20 | ~95% identical |
| `complete_job` | 20 | ~90% identical |
| `complete_with_no_items` | 19 | ~95% identical |
| `handle_error` | 8 | 100% identical |
| `store_import_error` | 8 | 100% identical |

| Abstract Method | Purpose |
|-----------------|---------|
| `find_list` | Load list by ID |
| `enrichment_id_key` | Metadata key for MB ID |
| `importer_class` | DataImporter class |
| `importer_params(mb_id)` | Hash of params for importer |
| `imported_id_key` | Metadata key for imported entity ID |

### 6. Base Enricher Service

**Path**: `app/lib/services/lists/music/base_list_item_enricher.rb`

```ruby
# reference only
module Services::Lists::Music
  class BaseListItemEnricher
    def initialize(list_item)
      @list_item = list_item
    end

    def call
      result = find_via_opensearch
      return result if result[:success]

      result = find_via_musicbrainz
      return result if result[:success]

      not_found_result
    end

    protected

    # Subclasses implement
    def opensearch_service_class    = raise NotImplementedError
    def musicbrainz_search_class    = raise NotImplementedError
    def entity_class                = raise NotImplementedError
    def entity_id_key               = raise NotImplementedError  # "song_id" or "album_id"
    def entity_name_key             = raise NotImplementedError  # "song_name" or "album_name"
    def mb_id_key                   = raise NotImplementedError  # "mb_recording_id" or "mb_release_group_id"
    def mb_name_key                 = raise NotImplementedError  # "mb_recording_name" or "mb_release_group_name"
    def mb_response_key             = raise NotImplementedError  # "recordings" or "release-groups"
    def lookup_existing_by_mb_id(mb_id) = raise NotImplementedError
  end
end
```

---

## Behaviors (pre/postconditions)

### Preconditions
- Both songs and albums wizards fully working
- All existing tests pass
- No active wizard sessions during migration

### Postconditions
- All existing tests still pass without modification
- Both wizards behave identically to before
- New base classes are tested independently
- Future media types can inherit from base classes

### Invariants
- Wizard step order unchanged: source → parse → enrich → validate → review → import → complete
- Job step configuration unchanged
- All URL routes unchanged
- All Turbo Stream responses unchanged

---

## Acceptance Criteria

### Phase 1: Shared Components
- [x] `Admin::Music::Wizard::SharedModalComponent` created and both wizards use it
- [x] Songs wizard tests pass with shared modal
- [x] Albums wizard tests pass with shared modal

### Phase 2: ListItemsActions Concern
- [x] `ListItemsActions` concern extracted
- [x] Songs `ListItemsActionsController` includes concern
- [x] Albums `ListItemsActionsController` includes concern
- [x] All item action tests pass for both wizards

### Phase 3: Base Controller
- [x] `Admin::Music::BaseListWizardController` created
- [x] Songs `ListWizardController` inherits from base
- [x] Albums `ListWizardController` inherits from base
- [x] All wizard tests pass for both

### Phase 4: Base Jobs
- [x] `WizardJobBase` concern created with shared job utilities
- [x] `Music::BaseWizardParseListJob` created and both parse jobs inherit
- [x] `Music::BaseWizardEnrichListItemsJob` created and both enrich jobs inherit
- [x] `Music::BaseWizardValidateListItemsJob` created and both validate jobs inherit
- [x] `Music::BaseWizardImportJob` created and both import jobs inherit
- [x] All job tests pass

### Phase 5: Base Enricher
- [x] `Services::Lists::Music::BaseListItemEnricher` created
- [x] Songs enricher inherits from base
- [x] Albums enricher inherits from base
- [x] All enricher tests pass

### Phase 6: Base Components
- [x] Base step components created for high-duplication components
- [x] Songs step components inherit from bases
- [x] Albums step components inherit from bases
- [x] All component tests pass

### Definition of Done
- [x] All tests pass (songs wizard, albums wizard)
- [x] No N+1 regressions (no new database queries added - only code reorganization)
- [x] Code review completed
- [x] Documentation updated

---

## Agent Hand-Off

### Constraints
- Refactor incrementally, one component at a time
- Each phase must have passing tests before proceeding
- Maintain backward compatibility at all times
- Do not change wizard behavior
- Follow existing project patterns (see `WizardController` concern as model)
- Use Rails generators for new files when applicable

### Required Outputs

#### Phase 1
- `app/components/admin/music/wizard/shared_modal_component.rb`
- `app/components/admin/music/wizard/shared_modal_component.html.erb`

#### Phase 2
- `app/controllers/concerns/list_items_actions.rb`
- Updated `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- Updated `app/controllers/admin/music/albums/list_items_actions_controller.rb`

#### Phase 3
- `app/controllers/admin/music/base_list_wizard_controller.rb`
- Updated `app/controllers/admin/music/songs/list_wizard_controller.rb`
- Updated `app/controllers/admin/music/albums/list_wizard_controller.rb`

#### Phase 4
- `app/sidekiq/music/base_wizard_parse_list_job.rb`
- `app/sidekiq/music/base_wizard_enrich_list_items_job.rb`
- `app/sidekiq/music/base_wizard_validate_list_items_job.rb`
- `app/sidekiq/music/base_wizard_import_job.rb`
- Updated songs and albums job files

#### Phase 5
- `app/lib/services/lists/music/base_list_item_enricher.rb`
- Updated `app/lib/services/lists/music/songs/list_item_enricher.rb`
- Updated `app/lib/services/lists/music/albums/list_item_enricher.rb`

#### Phase 6 (Optional)
- `app/components/admin/music/wizard/base_source_step_component.rb`
- `app/components/admin/music/wizard/base_parse_step_component.rb`
- `app/components/admin/music/wizard/base_enrich_step_component.rb`
- `app/components/admin/music/wizard/base_validate_step_component.rb`
- `app/components/admin/music/wizard/base_import_step_component.rb`

### Sub-Agent Plan
1) codebase-pattern-finder → Find existing concern/base class patterns (DONE)
2) codebase-analyzer → Compare songs/albums implementations side-by-side (DONE)
3) Implementation: Start with Phase 1 (lowest risk), progress through phases
4) technical-writer → Update docs/features/list-wizard.md with base class documentation

### Test Seed / Fixtures
- Use existing fixtures: `music/songs/lists.yml`, `music/albums/lists.yml`
- Use existing fixtures: `music/songs/list_items.yml`, `music/albums/list_items.yml`

---

## Implementation Notes (living)

### Analysis Completed
- Songs vs Albums ListWizardController: 89% duplication (263 of 295 code lines identical)
- Songs vs Albums ViewComponents: 85-100% Ruby duplication, 70-96% ERB duplication
- Songs vs Albums Background Jobs: 80-95% duplication (average 87%)
- Songs vs Albums ListItemEnricher: 95% duplication

### Recommended Implementation Order
1. **SharedModalComponent** - Zero risk, 100% identical
2. **ListItemsActions concern** - Low risk, clear shared actions
3. **BaseListWizardController** - Medium risk, highest impact
4. **Base Jobs** - Medium risk, isolated changes
5. **BaseListItemEnricher** - Low risk, service class
6. **Base Components** - Higher risk, defer if timeline tight

### Key Files Touched (paths only)
- `app/controllers/admin/music/base_list_wizard_controller.rb` (new)
- `app/controllers/concerns/list_items_actions.rb` (new)
- `app/controllers/admin/music/songs/list_wizard_controller.rb`
- `app/controllers/admin/music/albums/list_wizard_controller.rb`
- `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- `app/controllers/admin/music/albums/list_items_actions_controller.rb`
- `app/components/admin/music/wizard/shared_modal_component.rb` (new)
- `app/sidekiq/music/base_wizard_*.rb` (4 new files)
- `app/lib/services/lists/music/base_list_item_enricher.rb` (new)

### Challenges & Resolutions
- ViewComponent inheritance: Despite general recommendations, 85%+ duplication justifies base classes
- Path helper differences: Use abstract methods returning path helpers
- Metadata key differences: Use abstract methods for key names

### Deviations From Plan
- None. All phases completed as planned.

### Files Created/Modified

**Phase 1 - SharedModalComponent:**
- Created: `app/components/admin/music/wizard/shared_modal_component.rb`
- Created: `app/components/admin/music/wizard/shared_modal_component.html.erb`
- Created: `test/components/admin/music/wizard/shared_modal_component_test.rb`
- Modified: Songs/Albums SharedModalComponent now inherit from base

**Phase 2 - ListItemsActions Concern:**
- Created: `app/controllers/concerns/list_items_actions.rb`
- Modified: `app/controllers/admin/music/songs/list_items_actions_controller.rb` (reduced from 383 to 202 lines)
- Modified: `app/controllers/admin/music/albums/list_items_actions_controller.rb` (reduced from 472 to 265 lines)

**Phase 3 - BaseListWizardController:**
- Created: `app/controllers/admin/music/base_list_wizard_controller.rb` (260 lines of shared logic)
- Modified: `app/controllers/admin/music/songs/list_wizard_controller.rb` (reduced from 326 to 49 lines)
- Modified: `app/controllers/admin/music/albums/list_wizard_controller.rb` (reduced from 326 to 49 lines)

**Phase 4 - Base Jobs:**
- Created: `app/sidekiq/concerns/wizard_job_base.rb`
- Created: `app/sidekiq/music/base_wizard_parse_list_job.rb` (95 lines of shared parsing logic)
- Created: `app/sidekiq/music/base_wizard_enrich_list_items_job.rb` (130 lines of shared enrichment logic)
- Created: `app/sidekiq/music/base_wizard_validate_list_items_job.rb` (125 lines of shared validation logic)
- Created: `app/sidekiq/music/base_wizard_import_job.rb` (215 lines of shared import logic)
- Modified: `app/sidekiq/music/songs/wizard_parse_list_job.rb` (reduced from 72 to 34 lines)
- Modified: `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb` (reduced from 124 to 21 lines)
- Modified: `app/sidekiq/music/songs/wizard_validate_list_items_job.rb` (reduced from 115 to 24 lines)
- Modified: `app/sidekiq/music/songs/wizard_import_songs_job.rb` (reduced from 216 to 69 lines)
- Modified: `app/sidekiq/music/albums/wizard_parse_list_job.rb` (reduced from 72 to 33 lines)
- Modified: `app/sidekiq/music/albums/wizard_enrich_list_items_job.rb` (reduced from 126 to 21 lines)
- Modified: `app/sidekiq/music/albums/wizard_validate_list_items_job.rb` (reduced from 113 to 24 lines)
- Modified: `app/sidekiq/music/albums/wizard_import_albums_job.rb` (reduced from 222 to 35 lines)

**Phase 5 - BaseListItemEnricher:**
- Created: `app/lib/services/lists/music/base_list_item_enricher.rb` (195 lines of shared enrichment logic)
- Modified: `app/lib/services/lists/music/songs/list_item_enricher.rb` (reduced from 137 to 55 lines)
- Modified: `app/lib/services/lists/music/albums/list_item_enricher.rb` (reduced from 139 to 55 lines)

**Phase 6 - Base Step Components:**
- Created: `app/components/admin/music/wizard/base_source_step_component.rb` (37 lines)
- Created: `app/components/admin/music/wizard/base_source_step_component.html.erb` (shared template)
- Created: `app/components/admin/music/wizard/base_parse_step_component.rb` (77 lines)
- Created: `app/components/admin/music/wizard/base_enrich_step_component.rb` (102 lines)
- Created: `app/components/admin/music/wizard/base_validate_step_component.rb` (115 lines)
- Created: `app/components/admin/music/wizard/base_import_step_component.rb` (135 lines)
- Modified: `app/components/admin/music/songs/wizard/source_step_component.rb` (reduced from 21 to 16 lines)
- Modified: `app/components/admin/music/songs/wizard/parse_step_component.rb` (reduced from 14 to 36 lines, adds path helpers)
- Modified: `app/components/admin/music/songs/wizard/enrich_step_component.rb` (reduced from 75 to 32 lines)
- Modified: `app/components/admin/music/songs/wizard/validate_step_component.rb` (reduced from 88 to 36 lines)
- Modified: `app/components/admin/music/songs/wizard/import_step_component.rb` (reduced from 123 to 32 lines)
- Modified: `app/components/admin/music/albums/wizard/source_step_component.rb` (reduced from 21 to 16 lines)
- Modified: `app/components/admin/music/albums/wizard/parse_step_component.rb` (reduced from 14 to 36 lines, adds path helpers)
- Modified: `app/components/admin/music/albums/wizard/enrich_step_component.rb` (reduced from 75 to 32 lines)
- Modified: `app/components/admin/music/albums/wizard/validate_step_component.rb` (reduced from 87 to 36 lines)
- Modified: `app/components/admin/music/albums/wizard/import_step_component.rb` (reduced from 134 to 32 lines)
- Deleted: `app/components/admin/music/songs/wizard/source_step_component.html.erb` (uses base template)
- Deleted: `app/components/admin/music/albums/wizard/source_step_component.html.erb` (uses base template)

## Acceptance Results
- **Date**: 2025-12-29
- **Verifier**: Claude
- **Test Results**:
  - 7 shared wizard component tests: PASS
  - 219 songs/albums wizard component tests: PASS
  - 58 wizard controller tests: PASS
  - 73 list items actions controller tests: PASS
- **Artifacts**: All base classes and refactored implementations verified working

## Future Improvements
- **Cross-media extraction**: When implementing books/movies/games wizards, evaluate extracting truly generic base classes (e.g., `Media::BaseListWizardController`) from the Music base classes. The Music namespace is intentional for now - YAGNI principle.
- Apply same pattern to books, movies, games wizards when implemented
- Consider code generation for new media type wizards
- Extract AI task base classes if patterns emerge

## Related PRs
-

## Documentation Updated
- [x] `docs/features/list-wizard.md` - Add base class documentation
- [x] Class docs for new base classes (documented inline and in feature doc)

# 106 - Wizard Shared Base Classes Refactoring

## Status
- **Status**: Not Started
- **Priority**: Low
- **Created**: 2025-12-27
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Extract shared code between Music::Songs and Music::Albums wizard implementations into base classes and concerns. This reduces duplication and makes future media type wizards easier to implement.

**Goal**: DRY up wizard implementations without breaking existing functionality.
**Scope**: Base classes, concerns, shared components.
**Non-goals**: Changing wizard behavior or adding features.

## Context & Links
- Prerequisite: specs 100-105 (albums wizard) completed
- Songs wizard: `app/controllers/admin/music/songs/list_wizard_controller.rb`
- Albums wizard: `app/controllers/admin/music/albums/list_wizard_controller.rb`

## Identified Refactoring Opportunities

### 1. Base ListWizardController

**Problem**: Songs and Albums ListWizardControllers share 80%+ identical code.

**Solution**: Extract `Admin::Music::BaseListWizardController`

```ruby
# app/controllers/admin/music/base_list_wizard_controller.rb
class Admin::Music::BaseListWizardController < Admin::Music::BaseController
  include WizardController

  protected

  # Common step advancement logic
  def advance_from_job_step(step_name, config)
    # Shared job step handling
  end

  # Common step-specific handlers
  def handle_source_step_advance
    # Check import_source, route appropriately
  end

  def handle_review_step_advance
    # Validate items exist before proceeding
  end

  # Subclasses implement
  def list_class
    raise NotImplementedError
  end

  def job_step_config
    raise NotImplementedError
  end
end
```

**Migration Path**:
1. Create base controller
2. Update Songs controller to inherit from base
3. Test Songs wizard still works
4. Update Albums controller to inherit from base
5. Test Albums wizard

### 2. Base ListItemEnricher Service

**Problem**: Songs and Albums ListItemEnrichers are nearly identical.

**Solution**: Extract `Services::Lists::Music::BaseListItemEnricher`

```ruby
# app/lib/services/lists/music/base_list_item_enricher.rb
module Services::Lists::Music
  class BaseListItemEnricher
    def initialize(list_item)
      @list_item = list_item
    end

    def call
      opensearch_result = find_via_opensearch(title, artists)
      return opensearch_result if opensearch_result[:success]

      musicbrainz_result = find_via_musicbrainz(title, artists)
      return musicbrainz_result if musicbrainz_result[:success]

      not_found_result
    end

    protected

    # Subclasses implement
    def opensearch_service
      raise NotImplementedError
    end

    def musicbrainz_search_service
      raise NotImplementedError
    end

    def entity_class
      raise NotImplementedError
    end
  end
end
```

### 3. Base ListItemsActionsController

**Problem**: Songs and Albums ListItemsActionsControllers share significant code.

**Solution**: Extract concern `ListItemsActions`

```ruby
# app/controllers/concerns/list_items_actions.rb
module ListItemsActions
  extend ActiveSupport::Concern

  included do
    before_action :set_list
    before_action :set_item, except: [:musicbrainz_artist_search]
  end

  def verify
    # Shared verification logic
  end

  def metadata
    # Shared metadata update logic
  end

  def link_musicbrainz_artist
    # Shared artist linking logic
  end

  def musicbrainz_artist_search
    # Shared artist search (same for songs and albums)
  end

  protected

  def update_item_row_turbo_stream
    turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: { item: @item, list: @list })
  end

  def update_stats_turbo_stream
    turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: { list: @list })
  end
end
```

### 4. Shared Modal Components

**Problem**: EditMetadataModal, SharedModal are duplicated between songs and albums.

**Solution**: Extract to `app/components/admin/music/wizard/`

| Component | Scope |
|-----------|-------|
| `SharedModalComponent` | Generic modal container |
| `EditMetadataModalComponent` | JSON metadata editor |
| `SearchMusicbrainzArtistsModalComponent` | Artist search (shared between songs/albums) |

```ruby
# app/components/admin/music/wizard/shared_modal_component.rb
class Admin::Music::Wizard::SharedModalComponent < ViewComponent::Base
  # Generic modal container used by both songs and albums
end
```

### 5. Base Wizard Parse Job

**Problem**: Parse jobs follow identical pattern, differ only in AI task class.

**Solution**: Extract `Music::BaseWizardParseListJob`

```ruby
# app/sidekiq/music/base_wizard_parse_list_job.rb
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
  end

  protected

  def find_list(list_id)
    raise NotImplementedError
  end

  def parser_task_class
    raise NotImplementedError
  end

  def step_name
    "parse"
  end
end
```

### 6. Base AI Validator Task

**Problem**: Songs and Albums validator tasks share structure, differ in validation rules.

**Solution**: Extract `Services::Ai::Tasks::Lists::Music::BaseListItemsValidatorTask`

```ruby
# app/lib/services/ai/tasks/lists/music/base_list_items_validator_task.rb
module Services::Ai::Tasks::Lists::Music
  class BaseListItemsValidatorTask < Services::Ai::Tasks::BaseTask
    protected

    def system_message
      <<~MSG
        You are validating #{media_type} matches from a list import.
        #{validation_rules}
      MSG
    end

    # Subclasses implement
    def media_type
      raise NotImplementedError
    end

    def validation_rules
      raise NotImplementedError
    end
  end
end
```

## Behaviors (pre/postconditions)

**Preconditions:**
- Both songs and albums wizards fully working
- Comprehensive test coverage for both

**Postconditions:**
- All tests still pass
- No change in wizard behavior
- Less duplicated code

## Acceptance Criteria
- [ ] Base controller extracted and working
- [ ] Songs wizard tests pass with base controller
- [ ] Albums wizard tests pass with base controller
- [ ] Base enricher extracted
- [ ] ListItemsActions concern extracted
- [ ] Shared modal components extracted
- [ ] No regression in either wizard

---

## Agent Hand-Off

### Constraints
- Refactor incrementally, one component at a time
- Maintain backward compatibility
- All tests must pass after each refactoring step
- Do not change wizard behavior

### Required Outputs
- `app/controllers/admin/music/base_list_wizard_controller.rb`
- `app/controllers/concerns/list_items_actions.rb`
- `app/lib/services/lists/music/base_list_item_enricher.rb`
- `app/sidekiq/music/base_wizard_parse_list_job.rb`
- `app/components/admin/music/wizard/*.rb`
- Updated songs and albums controllers/services to use base classes

### Sub-Agent Plan
1) codebase-analyzer → Compare songs and albums implementations side-by-side
2) codebase-pattern-finder → Find other examples of base class extraction in project

### Test Seed / Fixtures
- Use existing fixtures for songs and albums

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- Multiple files in songs and albums wizard directories

### Challenges & Resolutions
-

### Deviations From Plan
-

## Acceptance Results
- Date, verifier, artifacts:

## Future Improvements
- Could apply same pattern to books, movies, games wizards
- Consider code generation for new media type wizards

## Related PRs
-

## Documentation Updated
- [ ] Update list-wizard.md with base class documentation

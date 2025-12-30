# List Wizard Infrastructure

## Summary

Multi-step wizard framework for importing and processing list data in admin interfaces. Provides reusable ViewComponents for wizard UI, a controller concern for step management, and integration patterns for background job processing. Currently implemented for Music::Songs::List and Music::Albums::List imports.

## Architecture Overview

The wizard infrastructure consists of four layers:

1. **Generic ViewComponents** (`app/components/wizard/`) - Reusable UI components
2. **WizardController Concern** - Base controller behavior for step navigation
3. **Domain-Specific Controllers** - Implementation for each list type
4. **Background Jobs** - Async processing with progress tracking via `wizard_state`

### Data Flow

```
User Action -> Controller -> wizard_state update -> Background Job
                                                         |
                                                         v
User Poll <- step_status JSON <- wizard_state <- Job Progress Update
```

### wizard_state JSON Storage

All wizard state is stored in the `wizard_state` JSONB column on the List model. This enables:
- Persistence across requests
- Progress tracking for background jobs
- Step-specific metadata storage
- Wizard restart/resume capability

## Generic Components

Located in [`app/components/wizard/`](/web-app/app/components/wizard/).

### ContainerComponent

Main wrapper component providing consistent wizard layout structure.

**File**: [`container_component.rb`](/web-app/app/components/wizard/container_component.rb)

**Parameters**:
- `wizard_id` (String) - DOM ID for the wizard container
- `current_step` (Integer) - Zero-based index of current step
- `total_steps` (Integer) - Total number of steps

**Slots**:
- `header` - Wizard title and description area
- `progress` - Step progress indicator
- `steps` - Step content (multiple)
- `navigation` - Back/Next buttons

### ProgressComponent

Displays numbered step indicator with completion status.

**File**: [`progress_component.rb`](/web-app/app/components/wizard/progress_component.rb)

**Parameters**:
- `steps` (Array) - Array of step hashes with `name` and `step` keys
- `current_step` (Integer) - Current step index
- `import_source` (String, optional) - Filters displayed steps based on source

**Key Methods**:
- `filtered_steps` - Returns steps applicable to current import source
- `step_status(original_step_index)` - Returns CSS class for step state (uses original index for correct comparison)
- `step_icon(original_step_index, display_position)` - Returns checkmark for completed, 1-based number for pending/current

### StepComponent

Container for individual step content.

**File**: [`step_component.rb`](/web-app/app/components/wizard/step_component.rb)

**Parameters**:
- `title` (String) - Step heading
- `description` (String, optional) - Step description
- `step_number` (Integer, optional) - Display number
- `active` (Boolean) - Whether step is currently active

**Slots**:
- `step_content` - Main step content
- `actions` - Step-specific action buttons

### NavigationComponent

Back/Next/Restart navigation buttons.

**File**: [`navigation_component.rb`](/web-app/app/components/wizard/navigation_component.rb)

**Parameters**:
- `list` (List) - The list entity being wizarded
- `step_name` (String) - Current step name
- `step_index` (Integer) - Current step index
- `total_steps` (Integer) - Total steps count
- `back_enabled` (Boolean) - Allow back navigation
- `next_enabled` (Boolean) - Allow forward navigation
- `next_label` (String) - Custom label for next button

**Key Methods**:
- `show_back_button?` - True if not on first step and back is enabled
- `show_next_button?` - True if not on last step
- `next_button_disabled?` - Disabled during job processing

## Controller Infrastructure

### Inheritance Hierarchy

The wizard controllers use a layered architecture:

```
WizardController (Concern)
    └── Admin::Music::BaseListWizardController
            ├── Admin::Music::Songs::ListWizardController
            └── Admin::Music::Albums::ListWizardController
```

### WizardController Concern

**File**: [`app/controllers/concerns/wizard_controller.rb`](/web-app/app/controllers/concerns/wizard_controller.rb)

Provides base wizard behavior that domain-specific controllers include.

### BaseListWizardController

**File**: [`app/controllers/admin/music/base_list_wizard_controller.rb`](/web-app/app/controllers/admin/music/base_list_wizard_controller.rb)

Provides shared functionality for music list wizards (songs and albums). Contains ~260 lines of shared logic including:
- Step advancement logic for all 7 steps
- Job-based step handling (parse, enrich, validate, import)
- Progress navigation
- Common step data loaders

Domain-specific controllers only need to implement:

| Method | Returns | Purpose |
|--------|---------|---------|
| `list_class` | Class | Model class for list (e.g., `Music::Songs::List`) |
| `entity_id_key` | String | Metadata key for entity ID (e.g., `"song_id"`) |
| `enrichment_id_key` | String | Metadata key for MusicBrainz ID (e.g., `"mb_recording_id"`) |
| `job_step_config` | Hash | Configuration for job-based wizard steps |

#### Included Callbacks

```ruby
before_action :set_wizard_entity
before_action :validate_step, only: [:show_step, :step_status, :advance_step, :back_step]
```

#### Required Implementations

Subclasses must implement:

| Method | Returns | Purpose |
|--------|---------|---------|
| `wizard_steps` | `Array<String>` | Ordered step names |
| `wizard_entity` | `ApplicationRecord` | Model instance with wizard_state |
| `set_wizard_entity` | void | Before action to load entity |

#### Optional Hooks

| Method | Parameters | Purpose |
|--------|------------|---------|
| `load_step_data(step_name)` | String | Load data for step view |
| `should_enqueue_job?(step_name)` | String | Return true for job-based steps |
| `enqueue_step_job(step_name)` | String | Start background processing |

#### Controller Actions

| Action | HTTP | Purpose |
|--------|------|---------|
| `show` | GET | Redirect to current step |
| `show_step` | GET | Render specific step view |
| `step_status` | GET | JSON status for AJAX polling |
| `advance_step` | POST | Move to next step |
| `back_step` | POST | Move to previous step |
| `restart` | POST | Reset wizard to beginning |

### Routes Configuration

Standard route definition for wizard controllers:

```ruby
resource :wizard, only: [:show], controller: "list_wizard" do
  get "step/:step", action: :show_step, as: :step
  get "step/:step/status", action: :step_status, as: :step_status
  post "step/:step/advance", action: :advance_step, as: :advance_step
  post "step/:step/back", action: :back_step, as: :back_step
  post "restart", action: :restart
  # Domain-specific actions
  post "save_html", action: :save_html, as: :save_html
  post "reparse", action: :reparse, as: :reparse
end
```

## Domain-Specific Implementation: Music::Songs

### ListWizardController

**File**: [`app/controllers/admin/music/songs/list_wizard_controller.rb`](/web-app/app/controllers/admin/music/songs/list_wizard_controller.rb)

#### Steps

| Step | Purpose | Background Job |
|------|---------|----------------|
| source | Select import method | No |
| parse | Parse HTML to extract items | `WizardParseListJob` |
| enrich | Add MusicBrainz data | `WizardEnrichListItemsJob` |
| validate | AI validation of matches | `WizardValidateListItemsJob` |
| review | Manual verification | No |
| import | Create song records | `WizardImportSongsJob` |
| complete | Summary display | No |

#### Job Step Configuration

The controller uses `JOB_STEP_CONFIG` to manage job-based steps:

```ruby
JOB_STEP_CONFIG = {
  "parse" => {
    job_class: "Music::Songs::WizardParseListJob",
    action_name: "Parsing",
    re_run_param: nil
  },
  "enrich" => {
    job_class: "Music::Songs::WizardEnrichListItemsJob",
    action_name: "Enrichment",
    re_run_param: :reenrich
  },
  # ...
}
```

### ListItemsActions Concern

**File**: [`app/controllers/concerns/list_items_actions.rb`](/web-app/app/controllers/concerns/list_items_actions.rb)

Provides shared actions for wizard list item manipulation. Used by both Songs and Albums `ListItemsActionsController`.

**Shared Actions**:
- `modal` - Loads modal content on-demand
- `verify` - Marks item as verified
- `metadata` - Updates item metadata from JSON
- `musicbrainz_artist_search` - JSON endpoint for artist autocomplete

**Required Implementations**:

| Method | Returns | Purpose |
|--------|---------|---------|
| `list_class` | Class | Model class for list |
| `partials_path` | String | Path prefix for partials |
| `valid_modal_types` | Array | Valid modal type strings |
| `shared_modal_component_class` | Class | Component class for error ID |
| `review_step_path` | String | Path to review step |

### SharedModalComponent

**File**: [`app/components/admin/music/wizard/shared_modal_component.rb`](/web-app/app/components/admin/music/wizard/shared_modal_component.rb)

Base modal component shared by both Songs and Albums wizards. Domain-specific subclasses inherit the constants:

```ruby
DIALOG_ID = "shared_modal_dialog"
FRAME_ID = "shared_modal_content"
ERROR_ID = "shared_modal_error"
```

Both `Admin::Music::Songs::Wizard::SharedModalComponent` and `Admin::Music::Albums::Wizard::SharedModalComponent` inherit from this base, maintaining backwards compatibility with existing constant references.

### Base Step Components

Located in [`app/components/admin/music/wizard/`](/web-app/app/components/admin/music/wizard/). These provide shared templates and logic for wizard steps.

| Base Component | Purpose | Subclass Overrides |
|----------------|---------|-------------------|
| `BaseSourceStepComponent` | Import source selection UI | `advance_path`, description text |
| `BaseParseStepComponent` | HTML parsing progress | `save_html_path`, `step_status_path` |
| `BaseEnrichStepComponent` | MusicBrainz enrichment progress | `step_status_path`, `advance_path` |
| `BaseValidateStepComponent` | AI validation progress | `enrichment_id_key`, `entity_id_key` |
| `BaseImportStepComponent` | Entity import progress | `enrichment_id_key`, path helpers |

#### Template Strategy

For components with >90% ERB duplication:
- Base component provides the template
- Subclasses only override path helper methods
- Use `content_for` blocks for entity-specific text

For components with <80% duplication (Review, Complete):
- Base component provides shared Ruby methods only
- Subclasses provide their own templates

### Step Components

Located in [`app/components/admin/music/songs/wizard/`](/web-app/app/components/admin/music/songs/wizard/).

| Component | Purpose |
|-----------|---------|
| `SourceStepComponent` | Import source selection |
| `ParseStepComponent` | HTML parsing progress |
| `EnrichStepComponent` | MusicBrainz enrichment |
| `ValidateStepComponent` | AI validation progress |
| `ReviewStepComponent` | Manual item review |
| `ImportStepComponent` | Song creation progress |
| `CompleteStepComponent` | Success summary |

### Helper Module

**File**: [`app/helpers/admin/music/songs/list_wizard_helper.rb`](/web-app/app/helpers/admin/music/songs/list_wizard_helper.rb)

| Method | Purpose |
|--------|---------|
| `render_step_component(step_name, list)` | Renders appropriate step component |
| `step_ready_to_advance?(step_name, list)` | Determines if Next button enabled |
| `next_button_label(step_name)` | Dynamic button text |
| `job_status_text(list)` | Human-readable job status |

### Review Step Item Actions

The review step provides per-item actions via a dropdown menu, handled by `ListItemsActionsController`:

| Action | Purpose |
|--------|---------|
| Edit Metadata | Manually edit the raw JSON metadata |
| Link Existing Song | Search and link to a song already in the database |
| Search MusicBrainz Recordings | Search for recordings within the matched artist's catalog |
| Search MusicBrainz Artists | Search and replace the artist match (useful when enrich step matched wrong artist) |

All actions use a shared modal component (`SharedModalComponent`) that loads content on-demand via Turbo Frames. Actions return Turbo Stream responses to update the table row and stats without page reload.

See [`ListItemsActionsController`](/docs/controllers/admin/music/songs/list_items_actions_controller.md) for full documentation.

### Review Step Performance Optimization

The review step uses CSS-based filtering for performance with large lists (1000+ items).

**Stimulus Controller**: [`review_filter_controller.js`](/web-app/app/javascript/controllers/review_filter_controller.js)

#### CSS-Based Filtering

Instead of iterating 1000+ rows in JavaScript, the controller sets a single `data-filter` attribute on the container and CSS handles visibility:

```css
[data-filter="valid"] tr[data-status]:not([data-status="valid"]) {
  display: none;
}
```

This reduces filter operations from O(n) to O(1).

#### Count Tracking

Counts are passed as Stimulus values for instant filter count updates:
- `data-review-filter-total-count-value`
- `data-review-filter-valid-count-value`
- `data-review-filter-invalid-count-value`
- `data-review-filter-missing-count-value`

A `MutationObserver` watches for Turbo Stream row updates and recounts when statuses change.

#### Stats Turbo Stream Updates

When items are modified via Turbo Stream (verify, link, metadata actions), the stats cards are updated via:

```ruby
turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list})
```

**Partial**: [`_review_stats.html.erb`](/web-app/app/views/admin/music/songs/list_items_actions/_review_stats.html.erb)

### Progress Component Step Filtering

When `import_source` is `musicbrainz_series`, the parse step is filtered from display. The `ProgressComponent` uses original step indices (not filtered positions) for status calculations to ensure correct highlighting:

```ruby
# Uses step[:step] (original index) for status comparison
step_status(step[:step])
# Uses both original index and display position for icons
step_icon(step[:step], index)
```

## wizard_state Schema

### Top-Level Structure

```json
{
  "current_step": 2,
  "started_at": "2025-01-19T10:00:00Z",
  "completed_at": null,
  "import_source": "custom_html",
  "steps": {
    "parse": { ... },
    "enrich": { ... }
  }
}
```

### Step-Level Structure

```json
{
  "status": "completed",
  "progress": 100,
  "error": null,
  "metadata": {
    "total_items": 50,
    "parsed_at": "2025-01-19T10:05:00Z"
  }
}
```

### Status Values

| Status | Meaning |
|--------|---------|
| `idle` | Step not started |
| `running` | Background job in progress |
| `completed` | Step finished successfully |
| `failed` | Step encountered error |

### Example: Complete wizard_state

```json
{
  "current_step": 4,
  "started_at": "2025-01-19T10:00:00Z",
  "completed_at": null,
  "import_source": "custom_html",
  "steps": {
    "parse": {
      "status": "completed",
      "progress": 100,
      "error": null,
      "metadata": {
        "total_items": 50,
        "parsed_at": "2025-01-19T10:05:00Z"
      }
    },
    "enrich": {
      "status": "completed",
      "progress": 100,
      "error": null,
      "metadata": {
        "enriched_count": 48,
        "no_match_count": 2
      }
    },
    "validate": {
      "status": "running",
      "progress": 45,
      "error": null,
      "metadata": {}
    }
  }
}
```

## Implementing for New List Type

### Step 1: Create Domain Controller

```ruby
# app/controllers/admin/books/list_wizard_controller.rb
class Admin::Books::ListWizardController < Admin::Books::BaseController
  include WizardController

  STEPS = %w[source parse enrich review import complete].freeze

  protected

  def wizard_steps
    STEPS
  end

  def wizard_entity
    @list
  end

  def load_step_data(step_name)
    # Load step-specific data
  end

  def should_enqueue_job?(step_name)
    %w[parse enrich import].include?(step_name)
  end

  def enqueue_step_job(step_name)
    case step_name
    when "parse"
      Books::WizardParseListJob.perform_async(@list.id)
    end
  end

  private

  def set_wizard_entity
    @list = Books::List.find(params[:list_id])
  end
end
```

### Step 2: Define Routes

```ruby
# config/routes.rb
namespace :admin do
  namespace :books do
    resources :lists do
      resource :wizard, only: [:show], controller: "list_wizard" do
        get "step/:step", action: :show_step, as: :step
        get "step/:step/status", action: :step_status, as: :step_status
        post "step/:step/advance", action: :advance_step, as: :advance_step
        post "step/:step/back", action: :back_step, as: :back_step
        post "restart", action: :restart
      end
    end
  end
end
```

### Step 3: Create Step Components

```ruby
# app/components/admin/books/wizard/source_step_component.rb
class Admin::Books::Wizard::SourceStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end
end
```

### Step 4: Create Background Jobs

```ruby
# app/sidekiq/books/wizard_parse_list_job.rb
class Books::WizardParseListJob
  include Sidekiq::Job

  def perform(list_id)
    list = Books::List.find(list_id)
    list.update_wizard_step_status(step: "parse", status: "running", progress: 0)

    # Processing logic...

    list.update_wizard_step_status(
      step: "parse",
      status: "completed",
      progress: 100,
      metadata: { total_items: count }
    )
  end
end
```

### Step 5: Create View Template

```erb
<%# app/views/admin/books/list_wizard/show_step.html.erb %>
<%= render(Wizard::ContainerComponent.new(
  wizard_id: "book_list_wizard",
  current_step: @step_index,
  total_steps: @wizard_steps.length
)) do |wizard| %>
  <% wizard.with_progress do %>
    <%= render(Wizard::ProgressComponent.new(
      steps: @wizard_steps.map.with_index { |name, idx| { name: name, step: idx } },
      current_step: @step_index
    )) %>
  <% end %>

  <%= render_step_component(@step_name, @list) %>

  <% wizard.with_navigation do %>
    <%= render(Wizard::NavigationComponent.new(
      list: @list,
      step_name: @step_name,
      step_index: @step_index,
      total_steps: @wizard_steps.length
    )) %>
  <% end %>
<% end %>
```

### Step 6: Create Helper Module

```ruby
# app/helpers/admin/books/list_wizard_helper.rb
module Admin::Books::ListWizardHelper
  def render_step_component(step_name, list)
    case step_name
    when "source"
      render(Admin::Books::Wizard::SourceStepComponent.new(list: list))
    # ...
    end
  end

  def step_ready_to_advance?(step_name, list)
    list.wizard_job_status != "running"
  end
end
```

### Step 7: Add Entry Point

Add wizard link to the list show page:

```erb
<%= link_to "Import Wizard", admin_books_list_wizard_path(@list), class: "btn btn-primary" %>
```

## File Structure Reference

### Generic Components

| File | Purpose |
|------|---------|
| [`app/components/wizard/container_component.rb`](/web-app/app/components/wizard/container_component.rb) | Main wrapper |
| [`app/components/wizard/progress_component.rb`](/web-app/app/components/wizard/progress_component.rb) | Step indicator |
| [`app/components/wizard/step_component.rb`](/web-app/app/components/wizard/step_component.rb) | Step container |
| [`app/components/wizard/navigation_component.rb`](/web-app/app/components/wizard/navigation_component.rb) | Navigation buttons |

### Controller Infrastructure

| File | Purpose |
|------|---------|
| [`app/controllers/concerns/wizard_controller.rb`](/web-app/app/controllers/concerns/wizard_controller.rb) | Base wizard concern |
| [`app/controllers/concerns/list_items_actions.rb`](/web-app/app/controllers/concerns/list_items_actions.rb) | Shared item actions |
| [`app/controllers/admin/music/base_list_wizard_controller.rb`](/web-app/app/controllers/admin/music/base_list_wizard_controller.rb) | Music wizard base |

### Shared Components

| File | Purpose |
|------|---------|
| [`app/components/admin/music/wizard/shared_modal_component.rb`](/web-app/app/components/admin/music/wizard/shared_modal_component.rb) | Base modal component |

### Music::Songs Implementation

| File | Purpose |
|------|---------|
| [`app/controllers/admin/music/songs/list_wizard_controller.rb`](/web-app/app/controllers/admin/music/songs/list_wizard_controller.rb) | Domain controller |
| [`app/helpers/admin/music/songs/list_wizard_helper.rb`](/web-app/app/helpers/admin/music/songs/list_wizard_helper.rb) | View helpers |
| [`app/views/admin/music/songs/list_wizard/show_step.html.erb`](/web-app/app/views/admin/music/songs/list_wizard/show_step.html.erb) | Step view |

### Music::Albums Implementation

| File | Purpose |
|------|---------|
| [`app/controllers/admin/music/albums/list_wizard_controller.rb`](/web-app/app/controllers/admin/music/albums/list_wizard_controller.rb) | Domain controller |
| [`app/helpers/admin/music/albums/list_wizard_helper.rb`](/web-app/app/helpers/admin/music/albums/list_wizard_helper.rb) | View helpers |
| [`app/views/admin/music/albums/list_wizard/show_step.html.erb`](/web-app/app/views/admin/music/albums/list_wizard/show_step.html.erb) | Step view |
| [`app/lib/services/lists/wizard/music/albums/state_manager.rb`](/web-app/app/lib/services/lists/wizard/music/albums/state_manager.rb) | Albums state manager |
| [`app/components/admin/music/albums/wizard/source_step_component.rb`](/web-app/app/components/admin/music/albums/wizard/source_step_component.rb) | Source selection |
| [`app/components/admin/music/albums/wizard/parse_step_component.rb`](/web-app/app/components/admin/music/albums/wizard/parse_step_component.rb) | Parse progress |
| [`app/components/admin/music/albums/wizard/enrich_step_component.rb`](/web-app/app/components/admin/music/albums/wizard/enrich_step_component.rb) | Enrichment |
| [`app/components/admin/music/albums/wizard/validate_step_component.rb`](/web-app/app/components/admin/music/albums/wizard/validate_step_component.rb) | AI validation |
| [`app/components/admin/music/albums/wizard/review_step_component.rb`](/web-app/app/components/admin/music/albums/wizard/review_step_component.rb) | Manual review |
| [`app/components/admin/music/albums/wizard/import_step_component.rb`](/web-app/app/components/admin/music/albums/wizard/import_step_component.rb) | Import progress |
| [`app/components/admin/music/albums/wizard/complete_step_component.rb`](/web-app/app/components/admin/music/albums/wizard/complete_step_component.rb) | Completion |
| [`app/sidekiq/music/albums/wizard_parse_list_job.rb`](/web-app/app/sidekiq/music/albums/wizard_parse_list_job.rb) | HTML parsing |
| [`app/sidekiq/music/albums/wizard_enrich_list_items_job.rb`](/web-app/app/sidekiq/music/albums/wizard_enrich_list_items_job.rb) | MusicBrainz enrichment |
| [`app/sidekiq/music/albums/wizard_validate_list_items_job.rb`](/web-app/app/sidekiq/music/albums/wizard_validate_list_items_job.rb) | AI validation |
| [`app/sidekiq/music/albums/wizard_import_albums_job.rb`](/web-app/app/sidekiq/music/albums/wizard_import_albums_job.rb) | Album import |

### Domain Step Components

| File | Purpose |
|------|---------|
| [`app/components/admin/music/songs/wizard/source_step_component.rb`](/web-app/app/components/admin/music/songs/wizard/source_step_component.rb) | Source selection |
| [`app/components/admin/music/songs/wizard/parse_step_component.rb`](/web-app/app/components/admin/music/songs/wizard/parse_step_component.rb) | Parse progress |
| [`app/components/admin/music/songs/wizard/enrich_step_component.rb`](/web-app/app/components/admin/music/songs/wizard/enrich_step_component.rb) | Enrichment |
| [`app/components/admin/music/songs/wizard/validate_step_component.rb`](/web-app/app/components/admin/music/songs/wizard/validate_step_component.rb) | AI validation |
| [`app/components/admin/music/songs/wizard/review_step_component.rb`](/web-app/app/components/admin/music/songs/wizard/review_step_component.rb) | Manual review |
| [`app/components/admin/music/songs/wizard/import_step_component.rb`](/web-app/app/components/admin/music/songs/wizard/import_step_component.rb) | Import progress |
| [`app/components/admin/music/songs/wizard/complete_step_component.rb`](/web-app/app/components/admin/music/songs/wizard/complete_step_component.rb) | Completion |

### View Partials

| File | Purpose |
|------|---------|
| [`app/views/admin/music/songs/list_items_actions/_item_row.html.erb`](/web-app/app/views/admin/music/songs/list_items_actions/_item_row.html.erb) | Review table row (Turbo Stream target) |
| [`app/views/admin/music/songs/list_items_actions/_review_stats.html.erb`](/web-app/app/views/admin/music/songs/list_items_actions/_review_stats.html.erb) | Stats cards (Turbo Stream target) |
| [`app/views/admin/music/songs/list_items_actions/_flash_success.html.erb`](/web-app/app/views/admin/music/songs/list_items_actions/_flash_success.html.erb) | Success message |
| [`app/views/admin/music/songs/list_items_actions/_error_message.html.erb`](/web-app/app/views/admin/music/songs/list_items_actions/_error_message.html.erb) | Error message |

### JavaScript Controllers

| File | Purpose |
|------|---------|
| [`app/javascript/controllers/wizard_step_controller.js`](/web-app/app/javascript/controllers/wizard_step_controller.js) | Job polling and progress updates |
| [`app/javascript/controllers/review_filter_controller.js`](/web-app/app/javascript/controllers/review_filter_controller.js) | CSS-based row filtering with MutationObserver |

### Background Jobs

#### Base Job Classes

| File | Purpose |
|------|---------|
| [`app/sidekiq/music/base_wizard_parse_list_job.rb`](/web-app/app/sidekiq/music/base_wizard_parse_list_job.rb) | Base parsing logic |
| [`app/sidekiq/music/base_wizard_enrich_list_items_job.rb`](/web-app/app/sidekiq/music/base_wizard_enrich_list_items_job.rb) | Base enrichment logic |
| [`app/sidekiq/music/base_wizard_validate_list_items_job.rb`](/web-app/app/sidekiq/music/base_wizard_validate_list_items_job.rb) | Base validation logic |
| [`app/sidekiq/music/base_wizard_import_job.rb`](/web-app/app/sidekiq/music/base_wizard_import_job.rb) | Base import logic |

##### BaseWizardParseListJob

Parses raw HTML to extract list items. Subclasses implement:

| Method | Purpose |
|--------|---------|
| `list_class` | Model class for list |
| `parser_task_class` | AI task for HTML parsing |
| `listable_type` | Polymorphic type string |
| `data_key` | Response key (`:songs` or `:albums`) |
| `build_metadata(item)` | Build metadata hash from parsed item |

##### BaseWizardEnrichListItemsJob

Enriches list items with MusicBrainz data. Subclasses implement:

| Method | Purpose |
|--------|---------|
| `list_class` | Model class for list |
| `enricher_class` | Service class for enrichment |
| `enrichment_keys` | Array of metadata keys to clear on re-enrich |

##### BaseWizardValidateListItemsJob

Validates enriched items using AI. Subclasses implement:

| Method | Purpose |
|--------|---------|
| `list_class` | Model class for list |
| `validator_task_class` | AI task class |
| `has_enrichment?(item)` | Check if item has enrichment data |

##### BaseWizardImportJob

Imports entities from MusicBrainz. Subclasses implement:

| Method | Purpose |
|--------|---------|
| `list_class` | Model class for list |
| `enrichment_id_key` | Metadata key for MB ID |
| `importer_class` | DataImporter class |
| `importer_params(mb_id)` | Hash of params for importer |
| `imported_id_key` | Metadata key for imported entity ID |

#### Songs Jobs

| File | Purpose |
|------|---------|
| [`app/sidekiq/music/songs/wizard_parse_list_job.rb`](/web-app/app/sidekiq/music/songs/wizard_parse_list_job.rb) | HTML parsing |
| [`app/sidekiq/music/songs/wizard_enrich_list_items_job.rb`](/web-app/app/sidekiq/music/songs/wizard_enrich_list_items_job.rb) | MusicBrainz enrichment |
| [`app/sidekiq/music/songs/wizard_validate_list_items_job.rb`](/web-app/app/sidekiq/music/songs/wizard_validate_list_items_job.rb) | AI validation |
| [`app/sidekiq/music/songs/wizard_import_songs_job.rb`](/web-app/app/sidekiq/music/songs/wizard_import_songs_job.rb) | Song creation |

### Services

| File | Purpose |
|------|---------|
| [`app/lib/services/lists/music/base_list_item_enricher.rb`](/web-app/app/lib/services/lists/music/base_list_item_enricher.rb) | Base enrichment service |
| [`app/lib/services/lists/music/songs/list_item_enricher.rb`](/web-app/app/lib/services/lists/music/songs/list_item_enricher.rb) | Song enrichment |
| [`app/lib/services/lists/music/albums/list_item_enricher.rb`](/web-app/app/lib/services/lists/music/albums/list_item_enricher.rb) | Album enrichment |

#### BaseListItemEnricher

**File**: [`app/lib/services/lists/music/base_list_item_enricher.rb`](/web-app/app/lib/services/lists/music/base_list_item_enricher.rb)

Provides shared enrichment logic for matching list items to existing entities. Searches OpenSearch first, then falls back to MusicBrainz.

**Subclass Requirements**:

| Method | Purpose |
|--------|---------|
| `opensearch_service_class` | OpenSearch lookup service |
| `entity_class` | Model class (e.g., `Music::Song`) |
| `entity_id_key` | Metadata key for entity ID |
| `entity_name_key` | Metadata key for entity name |
| `musicbrainz_search_service_class` | MusicBrainz search service |
| `musicbrainz_response_key` | Response key (e.g., `"recordings"`) |
| `musicbrainz_id_key` | Metadata key for MB ID |
| `musicbrainz_name_key` | Metadata key for MB name |
| `lookup_existing_by_mb_id(mb_id)` | Find existing entity by MB ID |

### Model Support

| File | Purpose |
|------|---------|
| [`app/models/list.rb`](/web-app/app/models/list.rb) | Base wizard_state methods |

## Related Documentation

- [List Model](/docs/models/list.md) - Base model with wizard_state methods
- [Music::Songs::List](/docs/models/music/songs/list.md) - Song list implementation
- [Music::Albums::List](/docs/models/music/albums/list.md) - Album list implementation
- [Spec Instructions](/docs/spec-instructions.md) - Spec tracking standards
- [Albums Wizard Specs](/docs/specs/) - Spec files 100-106 for albums wizard implementation

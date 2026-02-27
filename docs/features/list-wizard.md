# List Wizard Infrastructure

## Summary

Multi-step wizard framework for importing and processing list data in admin interfaces. Provides reusable ViewComponents for wizard UI, a controller concern for step management, and integration patterns for background job processing. Implemented for Music (Songs, Albums) and Games domains.

## Architecture Overview

The wizard infrastructure consists of five layers:

1. **Generic ViewComponents** (`app/components/wizard/`) - Reusable UI components
2. **WizardController Concern** - Base controller behavior for step navigation
3. **BaseListWizardController Concern** - Shared list wizard logic (7-step flow, job dispatching)
4. **Domain-Specific Controllers** - Implementation for each list type
5. **Background Jobs** - Async processing with progress tracking via `wizard_state`

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

The wizard controllers use a layered architecture with shared concerns:

```
WizardController (Concern)
    └── BaseListWizardController (Concern, includes WizardController)
            ├── Admin::Music::BaseListWizardController < Admin::Music::BaseController
            │       ├── Admin::Music::Songs::ListWizardController
            │       └── Admin::Music::Albums::ListWizardController
            └── Admin::Games::ListWizardController < Admin::Games::BaseController
```

Music uses a three-tier hierarchy (shared concern → music base class → song/album leaf). Games includes `BaseListWizardController` directly without an intermediate base class.

### WizardController Concern

**File**: [`app/controllers/concerns/wizard_controller.rb`](/web-app/app/controllers/concerns/wizard_controller.rb)

Provides generic wizard behavior: step navigation, validation, status polling, and restart.

**Controller Actions**:

| Action | HTTP | Purpose |
|--------|------|---------|
| `show` | GET | Redirect to current step |
| `show_step` | GET | Render specific step view |
| `step_status` | GET | JSON status for AJAX polling |
| `advance_step` | POST | Move to next step |
| `back_step` | POST | Move to previous step |
| `restart` | POST | Reset wizard to beginning |

**Abstract methods** (subclasses must implement):

| Method | Returns | Purpose |
|--------|---------|---------|
| `wizard_steps` | `Array<String>` | Ordered step names |
| `wizard_entity` | `ApplicationRecord` | Model instance with wizard_state |
| `set_wizard_entity` | void | Before action to load entity |

**No-op hooks** (override as needed):

| Method | Parameters | Purpose |
|--------|------------|---------|
| `load_step_data(step_name)` | String | Load data for step view |
| `should_enqueue_job?(step_name)` | String | Return true for job-based steps |
| `enqueue_step_job(step_name)` | String | Start background processing |

### BaseListWizardController Concern

**File**: [`app/controllers/concerns/base_list_wizard_controller.rb`](/web-app/app/controllers/concerns/base_list_wizard_controller.rb)

Domain-agnostic concern for the 7-step list wizard flow. Includes `WizardController` and provides:
- Step advancement logic for all 7 steps (source, parse, enrich, validate, review, import, complete)
- Job-based step handling with status tracking
- HTML save/reparse actions
- Step data loading with abstract hooks for domain-specific eager loading

**Abstract methods** (subclasses must implement):

| Method | Returns | Purpose |
|--------|---------|---------|
| `list_class` | Class | Model class for list (e.g., `Games::List`) |
| `entity_id_key` | String | Metadata key for entity ID (e.g., `"game_id"`) |
| `enrichment_id_key` | String | Metadata key for external ID (e.g., `"igdb_id"`) |
| `job_step_config` | Hash | Maps step names to `{job_class:, action_name:, re_run_param:}` |
| `load_review_step_data` | void | Domain-specific eager loading for review step |
| `load_import_step_data` | void | Domain-specific eager loading for import step |

**Optional overrides**:

| Method | Default | Purpose |
|--------|---------|---------|
| `valid_import_sources` | `["custom_html"]` | Allowed import source values |
| `source_step_next_index` | `1` (parse step) | Step to jump to after source selection |

### Routes Configuration

Standard route definition for wizard controllers:

```ruby
resource :wizard, only: [:show], controller: "list_wizard" do
  get "step/:step", action: :show_step, as: :step
  get "step/:step/status", action: :step_status, as: :step_status
  post "step/:step/advance", action: :advance_step, as: :advance_step
  post "step/:step/back", action: :back_step, as: :back_step
  post "restart", action: :restart
  # Shared HTML actions
  post "save_html", action: :save_html, as: :save_html
  post "reparse", action: :reparse, as: :reparse
  # Domain-specific actions (e.g., igdb_game_search for games)
end
```

### ListItemsActions Concern

**File**: [`app/controllers/concerns/list_items_actions.rb`](/web-app/app/controllers/concerns/list_items_actions.rb)

Provides shared actions for wizard list item manipulation during the review step. Used by Music (Songs, Albums) and Games `ListItemsActionsController`.

**Shared Actions**:
- `modal` - Loads modal content on-demand via Turbo Frames
- `verify` - Marks item as verified
- `destroy` - Deletes item
- `metadata` - Updates item metadata from JSON

**Abstract methods** (subclasses must implement):

| Method | Returns | Purpose |
|--------|---------|---------|
| `list_class` | Class | Model class for list |
| `partials_path` | String | Path prefix for partials |
| `valid_modal_types` | Array | Valid modal type strings |
| `shared_modal_component_class` | Class | Component class with `ERROR_ID` constant |
| `review_step_path` | String | Path to review step |

**Override hook**: `item_actions_for_set_item` - returns array of action names that require `@item` loaded. Default: `[:verify, :destroy, :metadata, :modal]`. Games adds `[:skip, :manual_link, :link_igdb_game, :re_enrich, :queue_import]`.

**Default `set_item`**: `@list.list_items.includes(listable: :artists).find(params[:id])`. Games overrides to `includes(listable: {game_companies: :company})`.

## Domain-Specific Implementations

### Music (Songs & Albums)

**Controller**: [`app/controllers/admin/music/base_list_wizard_controller.rb`](/web-app/app/controllers/admin/music/base_list_wizard_controller.rb)

Music shares an intermediate base class that provides:
- `valid_import_sources`: `["custom_html", "musicbrainz_series"]`
- `source_step_next_index`: returns 5 (review step) for `musicbrainz_series`, 1 (parse) otherwise
- `load_review_step_data`: eager loads `listable: :artists`, computes counts
- `load_import_step_data`: queries linked/unlinked/no-match items

Song/album leaf controllers implement `list_class`, `entity_id_key`, `enrichment_id_key`, and `job_step_config`.

| Step | Purpose | Background Job |
|------|---------|----------------|
| source | Select import method (HTML or MusicBrainz series) | No |
| parse | Parse HTML to extract items | `WizardParseListJob` |
| enrich | Add MusicBrainz data | `WizardEnrichListItemsJob` |
| validate | AI validation of matches | `WizardValidateListItemsJob` |
| review | Manual verification | No |
| import | Create song/album records | `WizardImportSongsJob` / `WizardImportAlbumsJob` |
| complete | Summary display | No |

**Review step item actions** (Music):

| Action | Purpose |
|--------|---------|
| Edit Metadata | Manually edit the raw JSON metadata |
| Link Existing Song/Album | Search and link to an entity already in the database |
| Search MusicBrainz Recordings/Releases | Search for matches within the matched artist's catalog |
| Search MusicBrainz Artists | Search and replace the artist match |
| Delete | Remove the list item permanently |

### Games

**Controller**: [`app/controllers/admin/games/list_wizard_controller.rb`](/web-app/app/controllers/admin/games/list_wizard_controller.rb)

Games includes `BaseListWizardController` directly (no intermediate base class). Key differences from music:
- `valid_import_sources`: `["custom_html"]` only (no series import)
- `entity_id_key`: `"game_id"`
- `enrichment_id_key`: `"igdb_id"`
- `load_review_step_data`: eager loads `listable: {game_companies: :company}`
- `load_import_step_data`: queries items by `igdb_id` metadata key

| Step | Purpose | Background Job |
|------|---------|----------------|
| source | Enter raw HTML | No |
| parse | Parse HTML to extract items | `Games::WizardParseListJob` |
| enrich | OpenSearch + IGDB enrichment | `Games::WizardEnrichListItemsJob` |
| validate | AI validation of matches | `Games::WizardValidateListItemsJob` |
| review | Manual verification | No |
| import | Create game records via IGDB importer | `Games::WizardImportGamesJob` |
| complete | Summary display | No |

**Review step item actions** (Games):

| Action | Purpose |
|--------|---------|
| Edit Metadata | Manually edit the raw JSON metadata |
| Link Existing Game | Search games in local DB, link to list item |
| Search IGDB Games | Search IGDB, select result, store igdb_id in metadata |
| Re-enrich | Re-runs enrichment for single item |
| Skip | Marks item as skipped/excluded |
| Verify | Marks item as verified |
| Delete | Remove the list item permanently |

**IGDB-specific endpoint**: `igdb_game_search` (GET) — JSON autocomplete searching IGDB with expanded fields (`involved_companies.company.name`, `involved_companies.developer`, `cover.image_id`). Debounced 300ms client-side, capped at 10 results.

**Items actions controller**: [`app/controllers/admin/games/list_items_actions_controller.rb`](/web-app/app/controllers/admin/games/list_items_actions_controller.rb)

## Background Jobs

### Inheritance Hierarchy

```
BaseWizardParseListJob
  ├─ Music::BaseWizardParseListJob (pass-through)
  │    ├─ Music::Songs::WizardParseListJob
  │    └─ Music::Albums::WizardParseListJob
  └─ Games::WizardParseListJob

BaseWizardEnrichListItemsJob
  ├─ Music::BaseWizardEnrichListItemsJob (pass-through)
  │    ├─ Music::Songs::WizardEnrichListItemsJob
  │    └─ Music::Albums::WizardEnrichListItemsJob
  └─ Games::WizardEnrichListItemsJob

BaseWizardValidateListItemsJob
  ├─ Music::BaseWizardValidateListItemsJob (pass-through)
  │    ├─ Music::Songs::WizardValidateListItemsJob
  │    └─ Music::Albums::WizardValidateListItemsJob
  └─ Games::WizardValidateListItemsJob

BaseWizardImportJob
  ├─ Music::BaseWizardImportJob (pass-through)
  │    ├─ Music::Songs::WizardImportSongsJob
  │    └─ Music::Albums::WizardImportAlbumsJob
  └─ Games::WizardImportGamesJob
```

Music has an intermediate pass-through base (e.g., `Music::BaseWizardParseListJob` inherits from `::BaseWizardParseListJob` with no additions). Games inherits directly from the top-level base classes.

### BaseWizardParseListJob

**File**: [`app/sidekiq/base_wizard_parse_list_job.rb`](/web-app/app/sidekiq/base_wizard_parse_list_job.rb)

Parses raw HTML to extract list items. Supports optional batch processing for large plain text lists.

| Method | Purpose |
|--------|---------|
| `list_class` | Model class for list |
| `parser_task_class` | AI task for HTML parsing |
| `listable_type` | Polymorphic type string |
| `data_key` | Response key (`:songs`, `:albums`, `:games`) |
| `build_metadata(item)` | Build metadata hash from parsed item |

### BaseWizardEnrichListItemsJob

**File**: [`app/sidekiq/base_wizard_enrich_list_items_job.rb`](/web-app/app/sidekiq/base_wizard_enrich_list_items_job.rb)

Enriches list items via OpenSearch + external API. Processes items sequentially with progress tracking.

| Method | Purpose |
|--------|---------|
| `list_class` | Model class for list |
| `enricher_class` | Service class for enrichment |
| `enrichment_keys` | Array of metadata keys to clear on re-enrich |
| `default_stats` | Hash of initial stat counters (e.g., `{opensearch_matches: 0, igdb_matches: 0}`) |
| `update_stats(result)` | Updates stats based on enrichment result source |

### BaseWizardValidateListItemsJob

**File**: [`app/sidekiq/base_wizard_validate_list_items_job.rb`](/web-app/app/sidekiq/base_wizard_validate_list_items_job.rb)

Validates enriched items using AI. Supports optional batch processing for large lists.

| Method | Purpose |
|--------|---------|
| `list_class` | Model class for list |
| `validator_task_class` | AI task class |
| `entity_id_key` | Metadata key for entity ID (e.g., `"song_id"`, `"game_id"`) |
| `enrichment_id_key` | Metadata key for external ID (e.g., `"mb_recording_id"`, `"igdb_id"`) |

### BaseWizardImportJob

**File**: [`app/sidekiq/base_wizard_import_job.rb`](/web-app/app/sidekiq/base_wizard_import_job.rb)

Imports entities from external APIs. Handles series import (music) and custom HTML import (all domains).

| Method | Purpose |
|--------|---------|
| `list_class` | Model class for list |
| `enrichment_id_key` | Metadata key for external ID |
| `importer_class` | DataImporter class |
| `importer_params(external_id)` | Hash of params for importer (e.g., `{igdb_id: id}` or `{musicbrainz_id: id}`) |
| `imported_id_key` | Metadata key for imported entity ID |
| `series_import_source_name` | Override for series import source name (default: `"musicbrainz_series"`) |

## Services

### Enricher Hierarchy

```
Services::Lists::BaseListItemEnricher
  ├─ Services::Lists::Music::BaseListItemEnricher
  │    ├─ Services::Lists::Music::Songs::ListItemEnricher
  │    └─ Services::Lists::Music::Albums::ListItemEnricher
  └─ Services::Lists::Games::ListItemEnricher
```

### BaseListItemEnricher

**File**: [`app/lib/services/lists/base_list_item_enricher.rb`](/web-app/app/lib/services/lists/base_list_item_enricher.rb)

Domain-agnostic base class providing two-tier enrichment: OpenSearch (local DB) first, then external API fallback.

**Abstract methods**:

| Method | Purpose |
|--------|---------|
| `opensearch_service_class` | OpenSearch lookup service |
| `entity_class` | Model class (e.g., `Music::Song`, `Games::Game`) |
| `entity_id_key` | Metadata key for entity ID |
| `entity_name_key` | Metadata key for entity name |
| `find_via_external_api(title, artists)` | External API search (MusicBrainz or IGDB) |

**Overridable methods**:

| Method | Default | Purpose |
|--------|---------|---------|
| `metadata_artists_key` | `"artists"` | Metadata key for the secondary search field. Games overrides to `"developers"` |
| `require_artists?` | `true` | Whether artists/developers are required. Games overrides to `false` (title-only enrichment) |
| `build_opensearch_enrichment_data(entity, score)` | Base fields | Music adds `opensearch_artist_names` |

### Music::BaseListItemEnricher

**File**: [`app/lib/services/lists/music/base_list_item_enricher.rb`](/web-app/app/lib/services/lists/music/base_list_item_enricher.rb)

Adds MusicBrainz-specific enrichment. Requires artists for enrichment (`require_artists?` defaults to `true`).

Additional abstract methods for music subclasses: `musicbrainz_search_service_class`, `musicbrainz_response_key`, `musicbrainz_id_key`, `musicbrainz_name_key`, `lookup_existing_by_mb_id`.

### Games::ListItemEnricher

**File**: [`app/lib/services/lists/games/list_item_enricher.rb`](/web-app/app/lib/services/lists/games/list_item_enricher.rb)

IGDB-based enrichment. Does **not** require developers (`require_artists?` returns `false`). Most game lists contain only titles, so title-only search works for both OpenSearch and IGDB.

Uses `IGDB_SEARCH_FIELDS` constant with expanded fields (`involved_companies.company.name`, `involved_companies.developer`, `cover.image_id`) to avoid IGDB returning unexpanded integer IDs.

OpenSearch: [`app/lib/search/games/search/game_by_title_and_developers.rb`](/web-app/app/lib/search/games/search/game_by_title_and_developers.rb) — accepts `artists:` parameter (renamed from `developers` for API compatibility with base enricher). Developers are optional and boost score when present.

## StateManager

**File**: [`app/lib/services/lists/wizard/state_manager.rb`](/web-app/app/lib/services/lists/wizard/state_manager.rb)

Factory-based wizard state management. `StateManager.for(list)` dispatches to domain-specific subclasses:
- `Music::Songs::List` → `Services::Lists::Wizard::Music::Songs::StateManager`
- `Music::Albums::List` → `Services::Lists::Wizard::Music::Albums::StateManager`
- `Games::List` → base `StateManager` (default steps match)

Key methods: `current_step`, `current_step_name`, `step_status(step)`, `step_progress(step)`, `update_step_status!`, `reset_step!`, `reset!`, `in_progress?`.

## Shared Components

### SharedModalComponent

**File**: [`app/components/admin/music/wizard/shared_modal_component.rb`](/web-app/app/components/admin/music/wizard/shared_modal_component.rb)

Base modal component with shared constants (`DIALOG_ID`, `FRAME_ID`, `ERROR_ID`). Domain-specific subclasses inherit from this:
- `Admin::Music::Songs::Wizard::SharedModalComponent`
- `Admin::Music::Albums::Wizard::SharedModalComponent`
- `Admin::Games::Wizard::SharedModalComponent`

### ItemRowComponent

**File**: [`app/components/wizard/item_row_component.rb`](/web-app/app/components/wizard/item_row_component.rb)

Domain-neutral base item row component for the review step table. Music inherits via `Admin::Music::Wizard::ItemRowComponent` (adds MusicBrainz source badge). Games inherits directly and overrides for domain-specific rendering (developers instead of artists, IGDB badge, game-specific menu items).

### Music Base Step Components

Located in [`app/components/admin/music/wizard/`](/web-app/app/components/admin/music/wizard/). These provide shared templates for music step components:

| Base Component | Purpose | Subclass Overrides |
|----------------|---------|-------------------|
| `BaseSourceStepComponent` | Import source selection UI | `advance_path`, description text |
| `BaseParseStepComponent` | HTML parsing progress | `save_html_path`, `step_status_path` |
| `BaseEnrichStepComponent` | MusicBrainz enrichment progress | `step_status_path`, `advance_path` |
| `BaseValidateStepComponent` | AI validation progress | `enrichment_id_key`, `entity_id_key` |
| `BaseImportStepComponent` | Entity import progress | `enrichment_id_key`, path helpers |

Games uses standalone step components (not inheriting from music bases) since they contain MusicBrainz-specific stats and references.

## Review Step Performance Optimization

The review step uses CSS-based filtering for performance with large lists (1000+ items).

**Stimulus Controller**: [`review_filter_controller.js`](/web-app/app/javascript/controllers/review_filter_controller.js)

### CSS-Based Filtering

Instead of iterating 1000+ rows in JavaScript, the controller sets a single `data-filter` attribute on the container and CSS handles visibility:

```css
[data-filter="valid"] tr[data-status]:not([data-status="valid"]) {
  display: none;
}
```

This reduces filter operations from O(n) to O(1).

### Count Tracking

Counts are passed as Stimulus values for instant filter count updates:
- `data-review-filter-total-count-value`
- `data-review-filter-valid-count-value`
- `data-review-filter-invalid-count-value`
- `data-review-filter-missing-count-value`

A `MutationObserver` watches for Turbo Stream row updates and recounts when statuses change.

### Stats Turbo Stream Updates

When items are modified via Turbo Stream (verify, link, metadata actions), the stats cards are updated via:

```ruby
turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list})
```

## wizard_state Schema

### Top-Level Structure

```json
{
  "current_step": 2,
  "started_at": "2025-01-19T10:00:00Z",
  "completed_at": null,
  "import_source": "custom_html",
  "batch_mode": false,
  "steps": {
    "parse": { ... },
    "enrich": { ... }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `current_step` | Integer | Zero-based index of current step |
| `started_at` | String | ISO8601 timestamp when wizard started |
| `completed_at` | String | ISO8601 timestamp when wizard completed |
| `import_source` | String | Import method (`custom_html`, `musicbrainz_series`) |
| `batch_mode` | Boolean | Enable batch processing for large lists (500+ items) |
| `steps` | Object | Per-step status and metadata |

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

## Batch Processing for Large Lists

For lists with 500+ items, the AI may return incomplete results. Batch processing solves this by splitting content into manageable chunks.

### Enabling Batch Mode

Users enable batch processing via a checkbox on the source step. The setting is stored in `wizard_state.batch_mode`.

**UI Location**: Source step, below the HTML/text input area

**Checkbox Label**: "Process in batches"

**Description**: "Enable for large plain text lists with one item per line (recommended for 500+ items). Processes 100 items at a time to ensure all items are captured."

### How Batch Processing Works

#### Parse Step

When batch mode is enabled:

1. Content is split by newlines
2. Empty/whitespace-only lines are filtered out
3. Lines are grouped into batches of 100
4. Each batch is parsed via `parser_task_class.new(parent: @list, content: batch_content)`
5. Positions are assigned cumulatively (batch 1: 1-100, batch 2: 101-200, etc.)
6. All items inserted atomically via `ListItem.insert_all`

#### Validate Step

When batch mode is enabled:

1. Enriched items are split into batches of 100
2. Each batch is validated via `validator_task_class.new(parent: @list, items: batch_items)`
3. Valid/invalid counts are aggregated across batches
4. Progress is updated after each batch completes

### Error Handling

**Fail-fast policy**: If any batch fails, the entire step fails. This prevents inconsistent data states.

- Error message includes batch number (e.g., "Batch 3 failed: AI timeout")
- Step can be re-run safely (idempotent via `destroy_all` for parse, `clear_previous_validation_flags` for validate)

### When to Use Batch Mode

| Scenario | Recommendation |
|----------|----------------|
| Plain text list, 500+ items | Enable batch mode |
| Plain text list, <500 items | Optional |
| HTML with complex structure | Do not enable (unpredictable splitting) |
| MusicBrainz series import | Not applicable (items come from API) |

## Implementing for New List Type

### Step 1: Create Domain Controller

```ruby
# reference only
# app/controllers/admin/books/list_wizard_controller.rb
class Admin::Books::ListWizardController < Admin::Books::BaseController
  include BaseListWizardController

  private

  def list_class = Books::List
  def entity_id_key = "book_id"
  def enrichment_id_key = "isbn"

  def job_step_config
    { "parse" => { job_class: "Books::WizardParseListJob", ... } }
  end

  def load_review_step_data
    @items = @list.list_items.includes(:listable).unverified
    # compute counts...
  end

  def load_import_step_data
    # query items by enrichment_id_key...
  end

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
        post "save_html", action: :save_html, as: :save_html
        post "reparse", action: :reparse, as: :reparse
      end
    end
  end
end
```

### Step 3: Create Background Jobs

Inherit from the shared base classes:

```ruby
# reference only
# app/sidekiq/books/wizard_parse_list_job.rb
class Books::WizardParseListJob < ::BaseWizardParseListJob
  def list_class = Books::List
  def parser_task_class = Services::Ai::Tasks::Lists::Books::RawParserTask
  def data_key = :books
  def listable_type = "Books::Book"
  def build_metadata(item)
    { "title" => item["title"], "authors" => item["authors"] }
  end
end
```

### Step 4: Create Enricher Service

Inherit from `BaseListItemEnricher`:

```ruby
# reference only
class Services::Lists::Books::ListItemEnricher < Services::Lists::BaseListItemEnricher
  def opensearch_service_class = Search::Books::Search::BookByTitleAndAuthors
  def entity_class = Books::Book
  def entity_id_key = "book_id"
  def entity_name_key = "book_name"
  def find_via_external_api(title, authors) = find_via_isbn(title, authors)
end
```

### Step 5: Create Step Components, View Template, and Helper Module

Follow the patterns in `app/components/admin/games/wizard/` for standalone components or `app/components/admin/music/wizard/` for inherited components.

### Step 6: Add StateManager Factory Entry

Add a case to `StateManager.for(list)` in [`app/lib/services/lists/wizard/state_manager.rb`](/web-app/app/lib/services/lists/wizard/state_manager.rb).

### Step 7: Add Entry Point

The wizard link is rendered automatically by the shared `Admin::Lists::ShowComponent` using `domain_config[:wizard_path_proc]`. To enable it for a new domain, implement the abstract `wizard_path` method in the domain's list controller (subclass of `Admin::ListsBaseController`):

```ruby
# reference only
# app/controllers/admin/books/lists_controller.rb
def wizard_path(list)
  admin_books_list_wizard_path(list_id: list.id)
end
```

## File Structure Reference

### Generic Components

| File | Purpose |
|------|---------|
| [`app/components/wizard/container_component.rb`](/web-app/app/components/wizard/container_component.rb) | Main wrapper |
| [`app/components/wizard/progress_component.rb`](/web-app/app/components/wizard/progress_component.rb) | Step indicator |
| [`app/components/wizard/step_component.rb`](/web-app/app/components/wizard/step_component.rb) | Step container |
| [`app/components/wizard/navigation_component.rb`](/web-app/app/components/wizard/navigation_component.rb) | Navigation buttons |
| [`app/components/wizard/item_row_component.rb`](/web-app/app/components/wizard/item_row_component.rb) | Base item row for review step |

### Controller Infrastructure

| File | Purpose |
|------|---------|
| [`app/controllers/concerns/wizard_controller.rb`](/web-app/app/controllers/concerns/wizard_controller.rb) | Generic wizard concern |
| [`app/controllers/concerns/base_list_wizard_controller.rb`](/web-app/app/controllers/concerns/base_list_wizard_controller.rb) | Shared list wizard concern |
| [`app/controllers/concerns/list_items_actions.rb`](/web-app/app/controllers/concerns/list_items_actions.rb) | Shared item actions |
| [`app/controllers/admin/music/base_list_wizard_controller.rb`](/web-app/app/controllers/admin/music/base_list_wizard_controller.rb) | Music wizard base |

### Shared Base Jobs

| File | Purpose |
|------|---------|
| [`app/sidekiq/base_wizard_parse_list_job.rb`](/web-app/app/sidekiq/base_wizard_parse_list_job.rb) | Base parsing logic |
| [`app/sidekiq/base_wizard_enrich_list_items_job.rb`](/web-app/app/sidekiq/base_wizard_enrich_list_items_job.rb) | Base enrichment logic |
| [`app/sidekiq/base_wizard_validate_list_items_job.rb`](/web-app/app/sidekiq/base_wizard_validate_list_items_job.rb) | Base validation logic |
| [`app/sidekiq/base_wizard_import_job.rb`](/web-app/app/sidekiq/base_wizard_import_job.rb) | Base import logic |

### Shared Components

| File | Purpose |
|------|---------|
| [`app/components/admin/music/wizard/shared_modal_component.rb`](/web-app/app/components/admin/music/wizard/shared_modal_component.rb) | Base modal component |
| [`app/components/wizard/item_row_component.rb`](/web-app/app/components/wizard/item_row_component.rb) | Base item row component |
| [`app/components/admin/music/wizard/item_row_component.rb`](/web-app/app/components/admin/music/wizard/item_row_component.rb) | Music item row component (adds MusicBrainz source badge) |

### Shared Helpers

| File | Purpose |
|------|---------|
| [`app/helpers/admin/lists_helper.rb`](/web-app/app/helpers/admin/lists_helper.rb) | Shared `count_items_json` and `items_json_to_string` methods (used by wizard step components and list show views) |

### Shared Services

| File | Purpose |
|------|---------|
| [`app/lib/services/lists/base_list_item_enricher.rb`](/web-app/app/lib/services/lists/base_list_item_enricher.rb) | Domain-agnostic enrichment base |
| [`app/lib/services/lists/wizard/state_manager.rb`](/web-app/app/lib/services/lists/wizard/state_manager.rb) | Wizard state factory |

### Music::Songs Implementation

| File | Purpose |
|------|---------|
| [`app/controllers/admin/music/songs/list_wizard_controller.rb`](/web-app/app/controllers/admin/music/songs/list_wizard_controller.rb) | Domain controller |
| [`app/controllers/admin/music/songs/list_items_actions_controller.rb`](/web-app/app/controllers/admin/music/songs/list_items_actions_controller.rb) | Item actions |
| [`app/helpers/admin/music/songs/list_wizard_helper.rb`](/web-app/app/helpers/admin/music/songs/list_wizard_helper.rb) | View helpers |
| [`app/views/admin/music/songs/list_wizard/show_step.html.erb`](/web-app/app/views/admin/music/songs/list_wizard/show_step.html.erb) | Step view |
| [`app/lib/services/lists/music/songs/list_item_enricher.rb`](/web-app/app/lib/services/lists/music/songs/list_item_enricher.rb) | Song enrichment |
| [`app/components/admin/music/songs/wizard/`](/web-app/app/components/admin/music/songs/wizard/) | Step components (7) + shared modal |

### Music::Albums Implementation

| File | Purpose |
|------|---------|
| [`app/controllers/admin/music/albums/list_wizard_controller.rb`](/web-app/app/controllers/admin/music/albums/list_wizard_controller.rb) | Domain controller |
| [`app/controllers/admin/music/albums/list_items_actions_controller.rb`](/web-app/app/controllers/admin/music/albums/list_items_actions_controller.rb) | Item actions |
| [`app/helpers/admin/music/albums/list_wizard_helper.rb`](/web-app/app/helpers/admin/music/albums/list_wizard_helper.rb) | View helpers |
| [`app/views/admin/music/albums/list_wizard/show_step.html.erb`](/web-app/app/views/admin/music/albums/list_wizard/show_step.html.erb) | Step view |
| [`app/lib/services/lists/music/albums/list_item_enricher.rb`](/web-app/app/lib/services/lists/music/albums/list_item_enricher.rb) | Album enrichment |
| [`app/components/admin/music/albums/wizard/`](/web-app/app/components/admin/music/albums/wizard/) | Step components (7) + shared modal |

### Games Implementation

| File | Purpose |
|------|---------|
| [`app/controllers/admin/games/list_wizard_controller.rb`](/web-app/app/controllers/admin/games/list_wizard_controller.rb) | Domain controller |
| [`app/controllers/admin/games/list_items_actions_controller.rb`](/web-app/app/controllers/admin/games/list_items_actions_controller.rb) | Item actions (skip, manual_link, link_igdb_game, re_enrich, igdb_game_search) |
| [`app/helpers/admin/games/list_wizard_helper.rb`](/web-app/app/helpers/admin/games/list_wizard_helper.rb) | View helpers |
| [`app/helpers/admin/games/list_items_actions_helper.rb`](/web-app/app/helpers/admin/games/list_items_actions_helper.rb) | Item label/metadata helpers |
| [`app/views/admin/games/list_wizard/show_step.html.erb`](/web-app/app/views/admin/games/list_wizard/show_step.html.erb) | Step view |
| [`app/views/admin/games/list_items_actions/`](/web-app/app/views/admin/games/list_items_actions/) | Partials + modals |
| [`app/lib/services/lists/games/list_item_enricher.rb`](/web-app/app/lib/services/lists/games/list_item_enricher.rb) | IGDB enrichment |
| [`app/lib/services/ai/tasks/lists/games/list_items_validator_task.rb`](/web-app/app/lib/services/ai/tasks/lists/games/list_items_validator_task.rb) | AI validation |
| [`app/lib/search/games/search/game_by_title_and_developers.rb`](/web-app/app/lib/search/games/search/game_by_title_and_developers.rb) | OpenSearch (title-only capable) |
| [`app/components/admin/games/wizard/`](/web-app/app/components/admin/games/wizard/) | Step components (7) + item row + shared modal |
| [`app/sidekiq/games/wizard_parse_list_job.rb`](/web-app/app/sidekiq/games/wizard_parse_list_job.rb) | HTML parsing |
| [`app/sidekiq/games/wizard_enrich_list_items_job.rb`](/web-app/app/sidekiq/games/wizard_enrich_list_items_job.rb) | OpenSearch + IGDB enrichment |
| [`app/sidekiq/games/wizard_validate_list_items_job.rb`](/web-app/app/sidekiq/games/wizard_validate_list_items_job.rb) | AI validation |
| [`app/sidekiq/games/wizard_import_games_job.rb`](/web-app/app/sidekiq/games/wizard_import_games_job.rb) | IGDB game import |

### JavaScript Controllers

| File | Purpose |
|------|---------|
| [`app/javascript/controllers/wizard_step_controller.js`](/web-app/app/javascript/controllers/wizard_step_controller.js) | Job polling and progress updates |
| [`app/javascript/controllers/review_filter_controller.js`](/web-app/app/javascript/controllers/review_filter_controller.js) | CSS-based row filtering with MutationObserver |

### Model Support

| File | Purpose |
|------|---------|
| [`app/models/list.rb`](/web-app/app/models/list.rb) | Base wizard_state methods |

## Related Documentation

- [List Model](/docs/models/list.md) - Base model with wizard_state methods
- [Music::Songs::List](/docs/models/music/songs/list.md) - Song list implementation
- [Music::Albums::List](/docs/models/music/albums/list.md) - Album list implementation
- [Games List Wizard Spec](/docs/specs/completed/games-list-wizard.md) - Games wizard implementation spec
- [IGDB API Wrapper](/docs/features/igdb-api-wrapper.md) - IGDB integration docs
- [Spec Instructions](/docs/spec-instructions.md) - Spec tracking standards

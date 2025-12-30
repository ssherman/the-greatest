# Admin::Music::Albums::Wizard::EnrichStepComponent

## Summary
ViewComponent that renders the enrich step UI for the album list wizard. Displays job progress, match statistics, and enriched items preview.

## Location
- Ruby: `app/components/admin/music/albums/wizard/enrich_step_component.rb`
- Template: `app/components/admin/music/albums/wizard/enrich_step_component.html.erb`

## Interface

### `initialize(list:, unverified_items: nil, enriched_count: nil)`
Creates the component for a given list.

**Parameters:**
- `list` (Music::Albums::List) - The list being enriched
- `unverified_items` (ActiveRecord::Relation, optional) - Preloaded items, defaults to `list.list_items.unverified.ordered`
- `enriched_count` (Integer, optional) - Precomputed count, defaults to items with `listable_id` present

## States

### 1. Idle (Ready to Enrich)
- Displays info alert about the enrichment process
- Shows stats: Total Items, Already Matched
- "Start Enrichment" button enabled

### 2. Running
- Progress bar with percentage
- Live stats: Processed, OpenSearch matches, MusicBrainz matches, Not Found
- Loading spinner
- `wizard-step` Stimulus controller attached for polling

### 3. Completed
- Success alert with total processed
- Final match statistics with percentages
- Scrollable preview table of all items
- "Re-enrich Items" button with confirmation

### 4. Failed
- Error alert with error message
- "Retry Enrichment" button

## Preview Table Columns

| Column | Description |
|--------|-------------|
| # | Position in list |
| Title | Album title from metadata |
| Artists | Comma-separated artist names |
| Match Source | Badge: OpenSearch / MusicBrainz / - |
| Status | Badge: Linked / MBID Found / No Match |

## Stimulus Integration

When job is running, attaches `wizard-step` controller with:
- `data-wizard-step-status-url-value` - Polls for job status
- `data-wizard-step-step-url-value` - Refreshes on completion
- Updates `progressBar` and `statusText` targets

## Helper Methods

| Method | Returns | Purpose |
|--------|---------|---------|
| `enrich_status` | String | Current step status from wizard_manager |
| `enrich_progress` | Integer | 0-100 progress percentage |
| `enrich_error` | String/nil | Error message if failed |
| `opensearch_matches` | Integer | Count from job metadata |
| `musicbrainz_matches` | Integer | Count from job metadata |
| `not_found_count` | Integer | Count from job metadata |
| `percentage(count)` | Float | Calculates percentage of total |
| `idle_or_failed?` | Boolean | Show start/retry button |
| `running?` | Boolean | Show progress UI |
| `completed?` | Boolean | Show results UI |

## Dependencies

- `Wizard::StepComponent` - Container component for step UI
- `wizard-step` Stimulus controller - Job polling
- DaisyUI components: stats, progress, alert, badge, table, button

## Routes Used

- `step_status_admin_albums_list_wizard_path` - Status polling endpoint
- `step_admin_albums_list_wizard_path` - Step refresh endpoint
- `advance_step_admin_albums_list_wizard_path` - Start/retry/re-enrich action

## Related Files

- `app/sidekiq/music/albums/wizard_enrich_list_items_job.rb` - Background job
- `app/helpers/admin/music/albums/list_wizard_helper.rb` - Dispatches to this component
- `app/javascript/controllers/wizard_step_controller.js` - Stimulus polling
- `test/components/admin/music/albums/wizard/enrich_step_component_test.rb` - 14 tests

## Usage

```ruby
# In helper or controller
render(Admin::Music::Albums::Wizard::EnrichStepComponent.new(list: @list))

# With preloaded data
render(Admin::Music::Albums::Wizard::EnrichStepComponent.new(
  list: @list,
  unverified_items: @unverified_items,
  enriched_count: @enriched_count
))
```

## Visual States

```
┌─────────────────────────────────────┐
│ Enrich Data                     [3] │
│ Enrich albums with metadata...      │
├─────────────────────────────────────┤
│                                     │
│ [Info Alert - Idle]                 │
│ Albums will be matched...           │
│                                     │
│ ┌─────────┬─────────┐               │
│ │Total: 50│Matched:5│               │
│ └─────────┴─────────┘               │
│                                     │
│ [Start Enrichment]                  │
│                                     │
└─────────────────────────────────────┘
```

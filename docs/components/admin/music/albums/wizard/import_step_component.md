# Admin::Music::Albums::Wizard::ImportStepComponent

## Summary
ViewComponent for the Import step (Step 6) of the Albums List Wizard. Displays import status, progress, and statistics during album import. Supports both custom HTML and MusicBrainz series import paths.

## Location
`app/components/admin/music/albums/wizard/import_step_component.rb`

## Interface

### `initialize(list:, all_items: nil, linked_items: nil, items_to_import: nil, items_without_match: nil)`

**Parameters:**
- `list` (Music::Albums::List) - Required. The list being imported.
- `all_items` (ActiveRecord::Relation) - Optional. Pre-loaded list items (defaults to `list.list_items.ordered`)
- `linked_items` (ActiveRecord::Relation) - Optional. Items with `listable_id` present
- `items_to_import` (ActiveRecord::Relation) - Optional. Items with `mb_release_group_id` but no `listable_id`
- `items_without_match` (ActiveRecord::Relation) - Optional. Items without `mb_release_group_id`

## States

The component renders different content based on the import step status:

### 1. Idle/Failed State
- Shows stats cards: Total Items, Already Linked, To Import, Without Match
- Displays items to import in a scrollable table (max 20 shown)
- Shows "Start Import" or "Retry Import" button
- If failed, displays error alert

### 2. Running State
- Shows progress bar with percentage
- Displays real-time stats: Processed, Imported, Failed
- Loading spinner with "Import in progress..." text
- Uses `wizard-step` Stimulus controller for polling

### 3. Completed State
- Shows success alert with "Import Complete!"
- Displays final stats: Imported, Skipped, Failed
- Collapsible section for failed items with error details
- "Complete Wizard" button to advance

## Import Paths

### Custom HTML Path
- Shows breakdown of items by category
- Table preview of items to import
- Stats: Total Items, Already Linked, To Import, Without Match

### MusicBrainz Series Path
- Shows series ID and list name
- Info alert about series import behavior
- Stats: Albums Imported, List Items Created, Failed

## Stimulus Integration

When `running?` is true, the component includes:
```html
<div data-controller="wizard-step"
     data-wizard-step-status-url-value="..."
     data-wizard-step-step-url-value="...">
```

This enables automatic polling and UI updates during job execution.

## Private Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `import_source` | String | "custom_html" or "musicbrainz_series" |
| `custom_html_path?` | Boolean | True if import_source is "custom_html" |
| `series_path?` | Boolean | True if import_source is "musicbrainz_series" |
| `import_status` | String | Current step status from wizard_manager |
| `import_progress` | Integer | Progress percentage (0-100) |
| `import_error` | String/nil | Error message if failed |
| `job_metadata` | Hash | Step metadata from wizard_manager |
| `imported_count` | Integer | Number of albums imported |
| `failed_count` | Integer | Number of failed imports |
| `skipped_count` | Integer | Number of skipped items |
| `idle_or_failed?` | Boolean | True if status is "idle" or "failed" |
| `running?` | Boolean | True if status is "running" |
| `completed?` | Boolean | True if status is "completed" |
| `can_start_import?` | Boolean | True if import can be started |

## Dependencies

- `Wizard::StepComponent` - Base step wrapper
- `wizard-step` Stimulus controller - Real-time polling
- DaisyUI components: stats, progress, alert, table, collapse

## Related Files

- `app/components/admin/music/albums/wizard/import_step_component.html.erb` - Template
- `app/sidekiq/music/albums/wizard_import_albums_job.rb` - Background job
- `app/controllers/admin/music/albums/list_wizard_controller.rb` - Controller
- `app/helpers/admin/music/albums/list_wizard_helper.rb` - Helper
- `test/components/admin/music/albums/wizard/import_step_component_test.rb` - 24 tests

## Usage

```erb
<%= render(Admin::Music::Albums::Wizard::ImportStepComponent.new(list: @list)) %>
```

Or with pre-loaded data:
```erb
<%= render(Admin::Music::Albums::Wizard::ImportStepComponent.new(
  list: @list,
  all_items: @all_items,
  linked_items: @linked_items,
  items_to_import: @items_to_import,
  items_without_match: @items_without_match
)) %>
```

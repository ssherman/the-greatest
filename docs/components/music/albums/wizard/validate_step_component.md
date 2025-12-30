# Admin::Music::Albums::Wizard::ValidateStepComponent

## Summary
ViewComponent that renders the validate step UI for the album list wizard. Uses AI to validate that enrichment matches are correct, displays validation progress, and shows results with valid/invalid counts.

## Location
- Ruby: `app/components/admin/music/albums/wizard/validate_step_component.rb`
- Template: `app/components/admin/music/albums/wizard/validate_step_component.html.erb`

## Interface

### `initialize(list:, enriched_items: nil)`
Creates the component for a given list.

**Parameters:**
- `list` (Music::Albums::List) - The list being validated
- `enriched_items` (Array, optional) - Preloaded items with enrichment data

## States

### 1. Idle (Ready to Validate)
- Displays info alert about AI validation process
- Shows stats: Total Items (unverified), Items to Validate (with matches)
- "Start Validation" button enabled

### 2. Running
- Progress bar with percentage
- Loading spinner with message
- `wizard-step` Stimulus controller attached for polling

### 3. Completed
- Success alert with total validated
- Final stats: Valid Matches, Invalid Matches, Auto-Verified
- AI Analysis card with reasoning (if available)
- Scrollable preview table of validation results
- "Re-validate Items" button with confirmation

### 4. Failed
- Error alert with error message
- "Retry Validation" button

## Preview Table Columns

| Column | Description |
|--------|-------------|
| # | Position in list |
| Original | Album title and artists from metadata |
| Matched To | Matched album name and artists |
| Source | Badge: OpenSearch / MusicBrainz |
| Status | Badge: Invalid (red) / Verified (green) / Pending (yellow) |

## Stimulus Integration

When job is running, attaches `wizard-step` controller with:
- `data-wizard-step-status-url-value` - Polls for job status
- `data-wizard-step-step-url-value` - Refreshes on completion
- Updates `progressBar` and `statusText` targets

## Helper Methods

| Method | Returns | Purpose |
|--------|---------|---------|
| `validate_status` | String | Current step status from wizard_manager |
| `validate_progress` | Integer | 0-100 progress percentage |
| `validate_error` | String/nil | Error message if failed |
| `valid_count` | Integer | Count from job metadata |
| `invalid_count` | Integer | Count from job metadata |
| `verified_count` | Integer | Count from job metadata |
| `validated_items` | Integer | Total validated from metadata |
| `reasoning` | String/nil | AI reasoning from metadata |
| `percentage(count)` | Float | Calculates percentage of validated |
| `idle_or_failed?` | Boolean | Show start/retry button |
| `running?` | Boolean | Show progress UI |
| `completed?` | Boolean | Show results UI |
| `failed?` | Boolean | Show error state |

## Dependencies

- `Wizard::StepComponent` - Container component for step UI
- `wizard-step` Stimulus controller - Job polling
- DaisyUI components: stats, progress, alert, badge, table, button, card

## Routes Used

- `step_status_admin_albums_list_wizard_path` - Status polling endpoint
- `step_admin_albums_list_wizard_path` - Step refresh endpoint
- `advance_step_admin_albums_list_wizard_path` - Start/retry/re-validate action

## Related Files

- `app/sidekiq/music/albums/wizard_validate_list_items_job.rb` - Background job
- `app/lib/services/ai/tasks/lists/music/albums/list_items_validator_task.rb` - AI task
- `app/helpers/admin/music/albums/list_wizard_helper.rb` - Dispatches to this component
- `app/javascript/controllers/wizard_step_controller.js` - Stimulus polling
- `app/components/admin/music/songs/wizard/validate_step_component.rb` - Songs equivalent
- `test/components/admin/music/albums/wizard/validate_step_component_test.rb` - Tests

## Usage

```ruby
# In helper or controller
render(Admin::Music::Albums::Wizard::ValidateStepComponent.new(list: @list))

# With preloaded enriched items
render(Admin::Music::Albums::Wizard::ValidateStepComponent.new(
  list: @list,
  enriched_items: @enriched_items
))
```

## Visual States

```
┌─────────────────────────────────────┐
│ Validate Matches                [4] │
│ Use AI to validate matches...       │
├─────────────────────────────────────┤
│                                     │
│ [Info Alert - Idle]                 │
│ AI will validate enriched matches   │
│ to detect bad matches...            │
│                                     │
│ ┌────────────┬───────────────┐      │
│ │ Total: 50  │ To Validate:45│      │
│ │ Unverified │ With matches  │      │
│ └────────────┴───────────────┘      │
│                                     │
│ [Start Validation]                  │
│                                     │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ Validate Matches                [4] │
├─────────────────────────────────────┤
│                                     │
│ [Success Alert]                     │
│ Validation Complete! 45 items       │
│                                     │
│ ┌──────────┬──────────┬──────────┐  │
│ │ Valid:40 │Invalid: 5│Verified:40│ │
│ │  88.9%   │  11.1%   │Ready      │ │
│ └──────────┴──────────┴──────────┘  │
│                                     │
│ ┌─────────────────────────────────┐ │
│ │ AI Analysis                     │ │
│ │ Items 3, 12, 24 matched to live │ │
│ │ recordings instead of studio... │ │
│ └─────────────────────────────────┘ │
│                                     │
│ [Re-validate Items]                 │
│                                     │
└─────────────────────────────────────┘
```

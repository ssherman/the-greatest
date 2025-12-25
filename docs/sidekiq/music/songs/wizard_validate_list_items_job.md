# Music::Songs::WizardValidateListItemsJob

## Summary
Sidekiq background job that validates enriched ListItems using AI. Part of the Song List Wizard Step 3 (Validate).

## Purpose
- Runs AI validation asynchronously to avoid blocking the UI
- Updates wizard step status with progress and results
- Handles validation results by marking items as valid/invalid
- Provides idempotent execution for safe retries

## Queue
Uses default Sidekiq queue.

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `list_id` | Integer | ID of the Music::Songs::List to validate |

## Workflow

1. Load list and identify enriched items (items with `listable_id`, `song_id`, or `mb_recording_id`)
2. If no enriched items, complete immediately with zero counts
3. Set wizard step status to "running"
4. Clear previous validation flags (for idempotency)
5. Call `ListItemsValidatorTask` for AI validation
6. Update wizard step status to "completed" or "failed"

## Wizard State Updates

**Running**:
```json
{
  "status": "running",
  "progress": 0,
  "metadata": {}
}
```

**Completed**:
```json
{
  "status": "completed",
  "progress": 100,
  "metadata": {
    "validated_items": 50,
    "valid_count": 45,
    "invalid_count": 5,
    "verified_count": 45,
    "reasoning": "...",
    "validated_at": "2025-12-03T15:30:00Z"
  }
}
```

**Failed**:
```json
{
  "status": "failed",
  "progress": 0,
  "error": "AI service timeout"
}
```

## Private Methods

### `#enriched_items`
Returns items that have enrichment data to validate.

### `#clear_previous_validation_flags`
Clears `ai_match_invalid` metadata and resets `verified = false` for idempotent re-runs.

### `#has_enrichment?(item)`
Checks if an item has enrichment data (`listable_id`, `song_id`, or `mb_recording_id`).

### `#complete_with_no_items`
Handles edge case when list has no enriched items.

### `#complete_job(data)`
Updates wizard state with successful validation results.

### `#handle_error(error_message)`
Updates wizard state with failure information.

## Error Handling

| Error | Behavior |
|-------|----------|
| `ActiveRecord::RecordNotFound` | Log error, re-raise |
| AI service failure | Update wizard state to failed, re-raise |
| Other exceptions | Update wizard state to failed, re-raise |

## Idempotency
The job is safe to retry:
- Clears previous `ai_match_invalid` flags before validation
- Resets `verified = false` for items that will be re-validated
- AI task processes all enriched items fresh

## Usage

```ruby
# Enqueue from controller
Music::Songs::WizardValidateListItemsJob.perform_async(list.id)

# Or run synchronously in console
Music::Songs::WizardValidateListItemsJob.new.perform(list.id)
```

## Dependencies
- `Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask`
- `Music::Songs::List` with `list_items` association
- `List#update_wizard_step_status` method

## Related Files
- `app/lib/services/ai/tasks/lists/music/songs/list_items_validator_task.rb` - AI task
- `app/controllers/admin/music/songs/list_wizard_controller.rb` - Controller that enqueues job
- `app/components/admin/music/songs/wizard/validate_step_component.rb` - UI component
- `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb` - Similar job pattern (enrich step)

## Logging
- Info: Job completion with counts
- Error: Job failures with error message

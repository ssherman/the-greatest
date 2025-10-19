# Music::Albums::ValidateListItemsJsonJob

## Summary
Sidekiq background job that validates MusicBrainz album matches in a Music::Albums::List's items_json field using AI. Queued from the Avo admin action to process lists asynchronously.

## Purpose
Provides asynchronous processing of AI validation for album matches. Each job validates all enriched albums in a single list, flagging invalid matches that can be reviewed in the items_json viewer tool.

## Job Configuration
- **Queue**: Default (not serial)
- **Retry**: Yes (Sidekiq default retry with exponential backoff)
- **Concurrency**: Safe for parallel execution (OpenAI has high rate limits)

## Public Methods

### `#perform(list_id)`
Executes the validation task for a single list
- Parameters:
  - `list_id` (Integer) - ID of the Music::Albums::List to validate
- Returns: nil
- Side Effects:
  - Updates list's items_json with `ai_match_invalid` flags
  - Logs success/failure with validation counts
  - Raises exceptions for retry on errors

## Execution Flow

1. Finds the Music::Albums::List by ID
2. Creates and calls ItemsJsonValidatorTask with the list
3. Logs success with validation counts (valid, invalid, total)
4. Logs errors on failure
5. Re-raises all exceptions for Sidekiq retry mechanism

## Error Handling

### RecordNotFound
- Logs error with list ID
- Re-raises for Sidekiq to mark job as failed
- Job will not retry (record doesn't exist)

### Unexpected Errors
- Logs error message
- Re-raises for Sidekiq retry
- Job will retry with exponential backoff

## Logging

### Success Log Format
```
ValidateListItemsJsonJob completed for list 123: 5 valid, 2 invalid
```

### Failure Log Format
```
ValidateListItemsJsonJob failed for list 123: <error message>
```

### RecordNotFound Log Format
```
ValidateListItemsJsonJob: List not found - <error message>
```

## Usage

### Enqueue Single Job
```ruby
Music::Albums::ValidateListItemsJsonJob.perform_async(list_id)
```

### Enqueue Multiple Jobs
```ruby
list_ids.each do |list_id|
  Music::Albums::ValidateListItemsJsonJob.perform_async(list_id)
end
```

### Monitor Job Status
Check Sidekiq dashboard or logs for job progress and any failures.

## Dependencies
- `Music::Albums::List` - ActiveRecord model
- `Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask` - AI validation task
- `Services::Ai::Result` - Result object from task

## Related Classes
- `Services::Ai::Tasks::Lists::Music::Albums::ItemsJsonValidatorTask` - The AI task this job invokes
- `Avo::Actions::Lists::Music::Albums::ValidateItemsJson` - Admin action that queues this job
- `Music::Albums::EnrichListItemsJsonJob` - Prerequisite job that adds MusicBrainz data

## Performance Considerations
- One job per list (not batched)
- Safe for parallel execution across multiple lists
- AI call happens synchronously within job
- Fast model (gpt-5-mini) keeps job duration short
- No rate limiting needed (OpenAI handles high throughput)

## Queue Strategy
Uses **default queue** instead of serial because:
- OpenAI has high rate limits (no throttling needed)
- Validation calls can run in parallel
- No resource contention between jobs
- Faster overall processing when validating multiple lists

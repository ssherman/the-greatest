# Music::Songs::ValidateListItemsJsonJob

## Summary
Sidekiq background job that validates MusicBrainz recording matches in a Music::Songs::List's items_json field using AI. Invokes the AI validation task and logs the results.

## Purpose
Provides asynchronous AI validation for song lists to:
- Avoid blocking admin UI during validation
- Handle long-running AI API calls
- Enable batch processing of multiple lists
- Provide retry capability on failures

## Location
`app/sidekiq/music/songs/validate_list_items_json_job.rb`

## Parent Class
- Includes `Sidekiq::Job` module

## Queue
Uses default Sidekiq queue (no custom queue specified).

**Rationale**: OpenAI has high rate limits, so serial queue not needed. Multiple validations can run in parallel.

## Public Methods

### `#perform(list_id)`
Validates song matches in a list's items_json using AI.

**Parameters**:
- `list_id` (Integer) - ID of Music::Songs::List to validate

**Process**:
1. Load list by ID
2. Instantiate AI validation task with list as parent
3. Call task to perform validation
4. Log success with validation counts
5. Log error on failure
6. Re-raise exceptions for Sidekiq retry

**Returns**: None (logs only)

**Raises**:
- `ActiveRecord::RecordNotFound` - If list_id doesn't exist
- `StandardError` - Any unexpected errors during validation

## Error Handling

### Record Not Found
When list ID is invalid:
- Logs error with message
- Re-raises exception (job marked as failed in Sidekiq)

### Validation Failure
When AI task returns failure:
- Logs error with result.error message
- Does not raise (job completes but validation failed)

### Unexpected Errors
Any other exceptions:
- Logs error with exception message
- Re-raises exception (enables Sidekiq retry mechanism)

## Logging

### Success Log
```ruby
Rails.logger.info "ValidateListItemsJsonJob completed for list #{list_id}:
  #{data[:valid_count]} valid, #{data[:invalid_count]} invalid"
```

### Failure Logs
```ruby
Rails.logger.error "ValidateListItemsJsonJob failed for list #{list_id}: #{result.error}"
Rails.logger.error "ValidateListItemsJsonJob: List not found - #{e.message}"
Rails.logger.error "ValidateListItemsJsonJob failed: #{e.message}"
```

## Invocation

### From Avo Action
```ruby
Music::Songs::ValidateListItemsJsonJob.perform_async(list.id)
```

### Manual Enqueueing
```ruby
# Immediate
Music::Songs::ValidateListItemsJsonJob.perform_async(123)

# Scheduled
Music::Songs::ValidateListItemsJsonJob.perform_in(1.hour, 123)
Music::Songs::ValidateListItemsJsonJob.perform_at(Time.zone.tomorrow.noon, 123)
```

## Data Flow

1. **Avo Action** - Queues job for each selected list
2. **Sidekiq** - Picks up job from default queue
3. **This Job** - Loads list, invokes AI task
4. **AI Task** - Validates matches, updates items_json
5. **Database** - items_json updated with ai_match_invalid flags
6. **Logs** - Success/failure recorded
7. **Admin** - Refreshes viewer to see results

## Retry Behavior

### Sidekiq Default Retries
- 25 retry attempts over 21 days (Sidekiq default)
- Exponential backoff between retries
- Applies to all raised exceptions

### No Retry Scenarios
- Validation returns failure (logged but not raised)
- Job completes successfully with partial validation

## Dependencies

### Required Models
- `Music::Songs::List` - Must exist with items_json field

### Required Services
- `Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask` - AI validation

### External Services
- OpenAI API (via validation task)

## Related Components
- **AI Task** - `Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask` (performs validation)
- **Avo Action** - `Avo::Actions::Lists::Music::Songs::ValidateItemsJson` (triggers this job)
- **Viewer Tool** - `Avo::ResourceTools::Lists::Music::Songs::ItemsJsonViewer` (displays results)
- **Parent Model** - `Music::Songs::List` (contains items_json)

## Testing
Comprehensive test coverage in `test/sidekiq/music/songs/validate_list_items_json_job_test.rb`:
- Success scenario with validation counts
- Failure scenario with error message
- Record not found exception
- Unexpected error exception
- Job enqueueing with Sidekiq::Testing.fake!
- Correct list loading by ID

6 tests, all passing with Mocha mocking.

## Performance Considerations

### Single List Per Job
Each job validates one list. Multiple lists are processed in parallel by separate jobs.

**Advantages**:
- Parallel processing across Sidekiq workers
- Isolated failures (one list failure doesn't affect others)
- Better progress tracking (per-list logging)
- Simpler retry logic

### AI API Timing
- Typical validation: 2-5 seconds for 50 songs
- Large lists (100+ songs): 5-10 seconds
- API timeout: Handled by OpenAI client (default 60s)

### Database Updates
- Single update per list (items_json JSONB field)
- No N+1 queries
- Minimal database load

## Monitoring

### Success Metrics
Monitor logs for:
- Validation completion messages
- Valid vs invalid counts per list
- Job execution time

### Error Metrics
Monitor for:
- RecordNotFound errors (invalid list IDs)
- AI task failures (API issues, timeout)
- Unexpected errors (code bugs)
- Retry counts and patterns

### Sidekiq Dashboard
- Queue depth (should stay near zero)
- Processing time (should be < 10s)
- Failure rate (should be < 1%)
- Retry queue depth

## Pattern Source
Based on `Music::Albums::ValidateListItemsJsonJob` (task 054) with namespace change for songs.

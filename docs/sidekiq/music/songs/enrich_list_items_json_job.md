# Music::Songs::EnrichListItemsJsonJob

## Summary
Sidekiq background job that enriches `items_json` on `Music::Songs::List` records with MusicBrainz metadata. Provides async processing wrapper around `Services::Lists::Music::Songs::ItemsJsonEnricher`.

## Purpose
Allows song list enrichment to run in the background without blocking the UI. Essential for lists with many songs where enrichment can take several minutes due to sequential MusicBrainz API calls.

## Public Methods

### `#perform(list_id)`
Executes the enrichment job for a specific list.

**Parameters:**
- `list_id` (Integer) - Primary key of Music::Songs::List to enrich

**Returns:**
- None (logs results instead)

**Processing Flow:**
1. Load `Music::Songs::List` by ID
2. Call `Services::Lists::Music::Songs::ItemsJsonEnricher.call(list: list)`
3. Log success or failure with appropriate level
4. Re-raise errors for Sidekiq retry logic

**Raises:**
- `ActiveRecord::RecordNotFound` - If list_id doesn't exist
- `StandardError` - Any unexpected errors (re-raised after logging)

**Example:**
```ruby
# Queue the job
Music::Songs::EnrichListItemsJsonJob.perform_async(123)

# Execute immediately (for testing)
Music::Songs::EnrichListItemsJsonJob.new.perform(123)
```

## Error Handling

### List Not Found
```ruby
rescue ActiveRecord::RecordNotFound => e
  Rails.logger.error "EnrichListItemsJsonJob: List not found - #{e.message}"
  raise
```
- Logs error with context
- Re-raises for Sidekiq to mark as failed
- No retry (record doesn't exist)

### Service Failures
```ruby
if result[:success]
  Rails.logger.info "EnrichListItemsJsonJob completed for list #{list_id}: #{result[:message]}"
else
  Rails.logger.error "EnrichListItemsJsonJob failed for list #{list_id}: #{result[:message]}"
end
```
- Service returns result hash (doesn't raise)
- Logs appropriate level based on success
- Job completes successfully even if enrichment partially fails

### Unexpected Errors
```ruby
rescue => e
  Rails.logger.error "EnrichListItemsJsonJob failed: #{e.message}"
  raise
```
- Catches any unexpected errors
- Logs with context
- Re-raises for Sidekiq retry logic

## Logging

### Success
**Level:** Info
```ruby
Rails.logger.info "EnrichListItemsJsonJob completed for list #{list_id}: Enriched 48 of 50 songs (2 skipped)"
```

### Failure
**Level:** Error
```ruby
Rails.logger.error "EnrichListItemsJsonJob failed for list #{list_id}: Test error message"
```

### List Not Found
**Level:** Error
```ruby
Rails.logger.error "EnrichListItemsJsonJob: List not found - Couldn't find Music::Songs::List with 'id'=999"
```

### Unexpected Errors
**Level:** Error
```ruby
Rails.logger.error "EnrichListItemsJsonJob failed: Unexpected error message"
```

## Dependencies

### Services
- `Services::Lists::Music::Songs::ItemsJsonEnricher` - Core enrichment logic

### Models
- `Music::Songs::List` - List being enriched

### Framework
- `Sidekiq::Job` - Background job framework
- `Rails.logger` - Logging

## Sidekiq Configuration

### Queue
Uses default Sidekiq queue (no explicit `queue_as` declaration)

### Retry
Inherits default Sidekiq retry behavior:
- 25 retries over ~21 days
- Exponential backoff
- Applies to raised exceptions only
- Service failures (result[:success] = false) don't trigger retries

### Concurrency
No special concurrency limits. Multiple jobs can run in parallel if Sidekiq workers are available.

## Usage Patterns

### Queue from Console
```ruby
# Single list
Music::Songs::EnrichListItemsJsonJob.perform_async(123)

# Multiple lists
list_ids = [123, 456, 789]
list_ids.each do |id|
  Music::Songs::EnrichListItemsJsonJob.perform_async(id)
end
```

### Queue from Avo Action
```ruby
# In Avo::Actions::Lists::Music::Songs::EnrichItemsJson
valid_lists.each do |list|
  Music::Songs::EnrichListItemsJsonJob.perform_async(list.id)
end
```

### Monitor Job Status
```ruby
# Check queue
Sidekiq::Queue.new.size

# Check for specific job
Sidekiq::Queue.new.find_job(job_id)
```

## Testing

Comprehensive test coverage in `test/sidekiq/music/songs/enrich_list_items_json_job_test.rb`:

### Test Scenarios (6 tests, 10 assertions)
- Job calls enricher service with correct list
- Logs success when enrichment succeeds
- Logs failure when enrichment fails
- Raises and logs when list not found
- Raises and logs on unexpected errors
- Can be enqueued with perform_async

### Testing Modes
```ruby
# Inline execution (for integration tests)
Sidekiq::Testing.inline! do
  Music::Songs::EnrichListItemsJsonJob.perform_async(123)
  # Job executes immediately
end

# Fake mode (for unit tests)
Sidekiq::Testing.fake! do
  expect {
    Music::Songs::EnrichListItemsJsonJob.perform_async(123)
  }.to change { Music::Songs::EnrichListItemsJsonJob.jobs.size }.by(1)
end
```

## Performance Considerations

### Processing Time
- Depends on number of songs in list
- ~1 second per song (MusicBrainz API calls)
- 50 songs ≈ 1 minute
- 100 songs ≈ 2 minutes

### Resource Usage
- Memory: Loads entire items_json into memory
- Network: One API call per song
- Database: One update at completion

### Monitoring
- Check Sidekiq web UI for job status
- Monitor logs for completion/failure messages
- Watch for retry patterns (indicates persistent errors)

## Related Classes
- `Services::Lists::Music::Songs::ItemsJsonEnricher` - Service this job wraps
- `Music::Albums::EnrichListItemsJsonJob` - Album version of this job
- `Avo::Actions::Lists::Music::Songs::EnrichItemsJson` - Triggers this job from UI

## Common Issues

### Job Stuck in Queue
- Check Sidekiq is running
- Verify queue name matches
- Check for dead jobs in Sidekiq UI

### Repeated Failures
- Check MusicBrainz API availability
- Verify list has valid items_json structure
- Review error logs for specific failure cause

### Memory Issues
- Very large lists (1000+ songs) may consume significant memory
- Consider splitting large lists if memory is constrained

# Music::Songs::ImportListItemsFromJsonJob

## Summary
Sidekiq background job that asynchronously imports songs from a list's `items_json` field into list_items. This job is a thin wrapper around `Services::Lists::Music::Songs::ItemsJsonImporter` that enables asynchronous processing to prevent timeouts and improve user experience. Part of the Music::Songs domain.

## Overview
This job enables background processing of song list imports, which is essential because:
- Importing songs from MusicBrainz can be slow (external API calls)
- Lists may contain hundreds of songs
- Processing should not block the admin UI or API requests
- Failed imports can be retried via Sidekiq's retry mechanism

The job follows the standard pattern of finding a record by ID and delegating business logic to a dedicated service class.

## Public Methods

### `#perform(list_id)`
Executes the background import job for a specific list.

- **Parameters**:
  - `list_id` (Integer) - The ID of the `Music::Songs::List` to process
- **Returns**: None (job returns are not used by Sidekiq)
- **Side Effects**:
  - Finds the list record
  - Calls `Services::Lists::Music::Songs::ItemsJsonImporter`
  - Creates new `Music::Song` records (via import)
  - Creates new `ListItem` records
  - Logs success/failure information
- **Raises**:
  - `ActiveRecord::RecordNotFound` - If list_id doesn't exist (logged and re-raised for Sidekiq retry)
  - Generic `StandardError` - For any other failures (logged and re-raised for Sidekiq retry)

## Job Configuration

### Queue
Uses the default Sidekiq queue (not explicitly configured).

### Retry Behavior
- Inherits Sidekiq's default retry behavior (25 retries with exponential backoff)
- Retries are appropriate for transient failures:
  - MusicBrainz API timeouts
  - Database connection issues
  - Temporary network failures

### Concurrency
No explicit concurrency limits. Multiple lists can be processed in parallel by different Sidekiq workers.

## Error Handling

### Record Not Found
```ruby
rescue ActiveRecord::RecordNotFound => e
  Rails.logger.error "ImportListItemsFromJsonJob: List not found - #{e.message}"
  raise  # Re-raise for Sidekiq retry/death queue
end
```
- Logs the specific error
- Re-raises to trigger Sidekiq retry mechanism
- After retries exhausted, job moves to dead queue

### General Errors
```ruby
rescue => e
  Rails.logger.error "ImportListItemsFromJsonJob failed: #{e.message}"
  raise  # Re-raise for Sidekiq retry/death queue
end
```
- Catches all other exceptions
- Logs for debugging
- Re-raises to enable retries

### Service-Level Results
The service returns a `Result` object with success status:
```ruby
if result.success
  Rails.logger.info "ImportListItemsFromJsonJob completed for list #{list_id}: ..."
else
  Rails.logger.error "ImportListItemsFromJsonJob failed for list #{list_id}: #{result.message}"
end
```
- Service failures are logged but not raised (job completes successfully)
- Individual song errors don't cause job failure
- Partial success is considered successful job completion

## Logging

The job logs at different levels:

### Info Level (Success)
```
ImportListItemsFromJsonJob completed for list 123: imported 25, created directly 60, skipped 10, errors 5
```
- Includes detailed counts from service result
- Provides visibility into import statistics

### Error Level (Job Failure)
```
ImportListItemsFromJsonJob: List not found - Couldn't find Music::Songs::List with 'id'=999
ImportListItemsFromJsonJob failed for list 123: Import failed: [error message]
ImportListItemsFromJsonJob failed: [exception message]
```
- Different messages for different failure types
- Includes list_id context when available

## Usage Examples

### Enqueueing the Job
```ruby
# From Avo admin action or controller
list = Music::Songs::List.find(123)
Music::Songs::ImportListItemsFromJsonJob.perform_async(list.id)
```

### Enqueueing with Delay
```ruby
# Process in 5 minutes
Music::Songs::ImportListItemsFromJsonJob.perform_in(5.minutes, list.id)

# Process at specific time
Music::Songs::ImportListItemsFromJsonJob.perform_at(1.hour.from_now, list.id)
```

### Monitoring Job Status
```ruby
# Check Sidekiq queue
require 'sidekiq/api'

queue = Sidekiq::Queue.new('default')
jobs = queue.select { |job| job.klass == 'Music::Songs::ImportListItemsFromJsonJob' }
puts "Pending import jobs: #{jobs.count}"
```

### Checking for Failures
```ruby
# Check dead queue
dead_set = Sidekiq::DeadSet.new
failed_imports = dead_set.select { |job|
  job.klass == 'Music::Songs::ImportListItemsFromJsonJob'
}
```

## Integration with Service Layer

The job delegates all business logic to the service:

```ruby
result = Services::Lists::Music::Songs::ItemsJsonImporter.call(list: list)
```

This separation of concerns provides:
- **Testability**: Service can be tested synchronously without Sidekiq
- **Flexibility**: Service can be called directly when background processing isn't needed
- **Maintainability**: Business logic centralized in service, job handles only infrastructure

## Admin UI Integration

This job is typically triggered from the Avo admin interface:

1. Admin navigates to a `Music::Songs::List` record
2. Admin clicks "Import Items from JSON" action
3. Avo action enqueues this job
4. Job processes in background
5. Admin can monitor via logs or Sidekiq UI

## Testing Approach

### Unit Testing
Test job-specific concerns:

1. **Job Enqueueing**:
   ```ruby
   expect {
     described_class.perform_async(list.id)
   }.to change(described_class.jobs, :size).by(1)
   ```

2. **Record Not Found Handling**:
   ```ruby
   expect {
     described_class.new.perform(999999)
   }.to raise_error(ActiveRecord::RecordNotFound)
   ```

3. **Service Integration**:
   ```ruby
   expect(Services::Lists::Music::Songs::ItemsJsonImporter)
     .to receive(:call).with(list: list)

   described_class.new.perform(list.id)
   ```

4. **Logging Behavior**:
   ```ruby
   allow(Rails.logger).to receive(:info)
   described_class.new.perform(list.id)
   expect(Rails.logger).to have_received(:info).with(/completed for list/)
   ```

### Integration Testing
Test end-to-end workflow:

1. **Successful Import**:
   - Create list with valid `items_json`
   - Enqueue and drain job
   - Verify list_items created
   - Verify songs imported/loaded

2. **Partial Success**:
   - Create list with mix of valid and invalid songs
   - Verify job completes successfully
   - Verify only valid songs processed

3. **Idempotency**:
   - Run job twice on same list
   - Verify no duplicate list_items
   - Verify appropriate skip counts

### Test Helpers
```ruby
# spec/support/sidekiq.rb
RSpec.configure do |config|
  config.before(:each) do
    Sidekiq::Worker.clear_all
  end
end

# In tests
require 'sidekiq/testing'

# Inline mode - jobs execute immediately
Sidekiq::Testing.inline! do
  Music::Songs::ImportListItemsFromJsonJob.perform_async(list.id)
end

# Fake mode - jobs enqueue but don't execute
Sidekiq::Testing.fake! do
  Music::Songs::ImportListItemsFromJsonJob.perform_async(list.id)
  expect(Music::Songs::ImportListItemsFromJsonJob.jobs.size).to eq(1)
end
```

## Performance Considerations

### Job Duration
Expected duration depends on:
- Number of songs in `items_json`
- Ratio of existing vs new songs
- MusicBrainz API response times
- Database performance

Typical ranges:
- 10 songs: 5-30 seconds
- 100 songs: 1-5 minutes
- 500 songs: 5-25 minutes

### Timeout Protection
Sidekiq's default timeout is 25 seconds, but this can be extended if needed:

```ruby
class Music::Songs::ImportListItemsFromJsonJob
  include Sidekiq::Job

  sidekiq_options timeout: 3600  # 1 hour for very large lists
end
```

### Memory Usage
- Job loads one list record
- Service processes songs sequentially
- Memory footprint is relatively small
- Large lists (1000+ songs) should still fit comfortably in memory

### Concurrency Considerations
- Multiple lists can import simultaneously
- No locking mechanism (lists are independent)
- Database uniqueness constraints prevent duplicate list_items
- MusicBrainz API rate limiting handled by provider layer

## Monitoring and Observability

### Sidekiq Dashboard
- View queued jobs: `/sidekiq` (if mounted)
- Monitor job duration
- Check retry counts
- Inspect failed jobs

### Application Logs
Search for:
```bash
# Successful imports
grep "ImportListItemsFromJsonJob completed" production.log

# Failed imports
grep "ImportListItemsFromJsonJob failed" production.log

# Specific list
grep "list 123" production.log | grep ImportListItemsFromJsonJob
```

### Metrics to Monitor
- Job duration (p50, p95, p99)
- Success rate
- Retry rate
- Dead queue size

## Troubleshooting

### Job Stuck in Queue
Check:
- Sidekiq workers are running
- No deadlocks or long-running jobs blocking workers
- Queue size and worker capacity

### Repeated Failures
Check:
- List still exists
- `items_json` is valid
- MusicBrainz API is accessible
- Database connections available

### Partial Imports
- Check service result logs for skip/error details
- Verify `items_json` enrichment quality
- Review individual song error messages

## Related Documentation
- [Services::Lists::Music::Songs::ItemsJsonImporter](/home/shane/dev/the-greatest/docs/models/services/lists/music/songs/items_json_importer.md) - Core business logic
- [Music::Songs::List](/home/shane/dev/the-greatest/docs/models/music/songs/list.md) - List model
- [ListItem](/home/shane/dev/the-greatest/docs/models/list_item.md) - Join model
- [Music::Song](/home/shane/dev/the-greatest/docs/models/music/song.md) - Song model

## See Also
- Avo action: `Avo::Actions::Lists::Music::Songs::ImportItemsFromJson` - Admin UI trigger
- Task documentation: [`docs/todos/066-import-songs-from-items-json.md`](/home/shane/dev/the-greatest/docs/todos/066-import-songs-from-items-json.md)
- Sidekiq documentation: https://github.com/sidekiq/sidekiq/wiki

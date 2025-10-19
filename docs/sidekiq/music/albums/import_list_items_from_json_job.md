# Music::Albums::ImportListItemsFromJsonJob

## Summary
Sidekiq background job that imports albums and creates list_items from enriched items_json data in a Music::Albums::List. This is the final phase of the three-phase list import workflow. Queued from the Avo admin action to process lists asynchronously.

## Purpose
Provides asynchronous processing of album imports and list_item creation. Each job processes all enriched and validated albums in a single list, creating verified list_items while preventing duplicates.

## Job Configuration
- **Queue**: Default (not serial)
- **Retry**: Yes (Sidekiq default retry with exponential backoff)
- **Concurrency**: Safe for parallel execution (each list processed independently)

## Public Methods

### `#perform(list_id)`
Executes the import service for a single list
- Parameters:
  - `list_id` (Integer) - ID of the Music::Albums::List to process
- Returns: nil
- Side Effects:
  - Imports albums from MusicBrainz if needed
  - Creates verified list_items with proper positioning
  - Logs success/failure with detailed statistics
  - Raises exceptions for retry on errors

## Execution Flow

1. Finds the Music::Albums::List by ID
2. Calls `Services::Lists::Music::Albums::ItemsJsonImporter.call(list: list)`
3. Logs success with import statistics (imported, created_directly, skipped, errors)
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
ImportListItemsFromJsonJob completed for list 123: imported 15, created directly 45, skipped 3, errors 0
```

### Failure Log Format
```
ImportListItemsFromJsonJob failed for list 123: <error message>
```

### RecordNotFound Log Format
```
ImportListItemsFromJsonJob: List not found - <error message>
```

## Usage

### Enqueue Single Job
```ruby
Music::Albums::ImportListItemsFromJsonJob.perform_async(list_id)
```

### Enqueue Multiple Jobs
```ruby
list_ids.each do |list_id|
  Music::Albums::ImportListItemsFromJsonJob.perform_async(list_id)
end
```

### Monitor Job Status
Check Sidekiq dashboard or logs for job progress and any failures.

## Dependencies
- `Music::Albums::List` - ActiveRecord model
- `Services::Lists::Music::Albums::ItemsJsonImporter` - Service that performs the import
- `DataImporters::Music::Album::Importer` - Used by service to import missing albums
- `ListItem` - Polymorphic model for list items

## Related Classes
- `Services::Lists::Music::Albums::ItemsJsonImporter` - The service this job invokes
- `Avo::Actions::Lists::Music::Albums::ImportItemsFromJson` - Admin action that queues this job
- `Music::Albums::EnrichListItemsJsonJob` - Phase 1 job that adds MusicBrainz data
- `Music::Albums::ValidateListItemsJsonJob` - Phase 2 job that validates matches with AI

## Performance Considerations
- One job per list (not batched)
- Safe for parallel execution across multiple lists
- Duration varies based on number of albums and how many need importing
- Albums already in database are fast (direct load)
- New albums require MusicBrainz API calls (slower)
- Service tracks both counts for performance visibility

## Queue Strategy
Uses **default queue** instead of serial because:
- Each list processed independently (no shared state)
- MusicBrainz has reasonable rate limits (importer handles throttling)
- Album imports can run in parallel across different jobs
- Faster overall processing when importing multiple lists

## Three-Phase Workflow
This job completes the final phase of list import:
1. **Phase 1 - Enrichment**: `EnrichListItemsJsonJob` adds MusicBrainz metadata to items_json
2. **Phase 2 - Validation**: `ValidateListItemsJsonJob` flags invalid matches with AI
3. **Phase 3 - Import** (this job): Creates verified list_items from validated data

## Idempotent Design
The underlying service is idempotent - safe to re-run on the same list:
- Duplicate list_items are prevented
- Existing albums are not re-imported
- Failed imports can be retried
- Partial success is tracked (some albums may succeed while others fail)

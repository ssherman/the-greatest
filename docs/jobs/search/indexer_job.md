# Search::IndexerJob

## Summary
Sidekiq background job that processes OpenSearch indexing queue. Runs every 30 seconds via sidekiq-cron to bulk index and unindex models efficiently without blocking the main application.

## Schedule
- **Frequency**: Every 30 seconds (`*/30 * * * * *`)
- **Queue**: Default Sidekiq queue
- **Framework**: Pure Sidekiq job (not ActiveJob)

## Public Methods

### `#perform`
Main job execution method that processes all pending `SearchIndexRequest` records
- Processes each indexed model type: Music::Artist, Music::Album, Music::Song
- Groups requests by model type and action for efficient bulk operations
- Limits processing to 1000 requests per model type per run
- Cleans up all processed requests after completion

## Processing Logic

### Request Grouping
1. Fetches oldest requests first (up to 1000 per model type)
2. Groups by `(parent_type, parent_id, action)` for deduplication
3. Separates into index and unindex operations

### Index Operations
- Loads models with `find_by(id:)` to skip deleted items
- Reloads with associations if `index_class.model_includes` is present
- Calls `index_class.bulk_index(models)` for efficient batch indexing
- Logs warnings for deleted items that can't be indexed

### Unindex Operations
- Collects parent IDs directly (no model loading needed)
- Calls `index_class.bulk_unindex(item_ids)` for efficient batch removal
- Works even if original models are deleted

### Cleanup
- Deletes ALL processed `SearchIndexRequest` records (including duplicates)
- Logs processing statistics and cleanup counts

## Error Handling
- Gracefully handles missing models during indexing
- Continues processing other requests if individual items fail
- Relies on underlying index classes for OpenSearch error handling
- Logs warnings for skipped operations

## Performance Features
- **Deduplication**: Multiple requests for same item processed as single operation
- **Bulk Operations**: Uses efficient OpenSearch bulk APIs
- **Memory Management**: Processes maximum 1000 requests per type per run
- **Association Loading**: Only loads model associations when required by index class
- **Efficient Queries**: Uses optimized database queries with proper ordering

## Dependencies
- `SearchIndexRequest` model for queue management
- OpenSearch index classes: `Search::Music::ArtistIndex`, `Search::Music::AlbumIndex`, `Search::Music::SongIndex`
- Sidekiq for background job processing
- sidekiq-cron for scheduling

## Configuration
Configured in `config/schedule.yml`:
```yaml
search_indexing:
  cron: "*/30 * * * * *"
  class: "Search::IndexerJob"
```

## Logging
- Job start/completion messages
- Processing counts per model type
- Warnings for deleted items during indexing
- Cleanup statistics including duplicate counts

## Monitoring
- Sidekiq Web UI available at `/sidekiq-admin` (with basic auth)
- Job execution history and failure tracking
- Queue depth monitoring via `SearchIndexRequest.count`

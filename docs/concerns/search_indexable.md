# SearchIndexable

## Summary
ActiveSupport::Concern that provides standardized OpenSearch indexing callbacks for models. Automatically queues indexing operations for background processing without blocking the main application thread.

## Usage
Include in any model that should be indexed in OpenSearch:

```ruby
class Music::Artist < ApplicationRecord
  include SearchIndexable
  # ... rest of model
end
```

## Callbacks
- `after_save :queue_for_indexing` - Queues indexing request when model is created or updated
- `after_destroy :queue_for_unindexing` - Queues unindexing request when model is destroyed

## Private Methods

### `#queue_for_indexing`
Creates a `SearchIndexRequest` with action `:index_item` for the current model instance
- Called automatically after save operations
- Queues the model for background indexing via `Search::IndexerJob`

### `#queue_for_unindexing`
Creates a `SearchIndexRequest` with action `:unindex_item` for the current model instance
- Called automatically after destroy operations
- Queues the model for background removal from OpenSearch via `Search::IndexerJob`

## Dependencies
- `SearchIndexRequest` model for queue management
- `Search::IndexerJob` for background processing
- Models must have corresponding OpenSearch index classes (e.g., `Search::Music::ArtistIndex`)

## Design Decisions
- Uses `after_save` and `after_destroy` callbacks for test compatibility
- Creates queue records immediately but processes them asynchronously
- Allows duplicate queue entries - deduplication handled in the background job
- Does not validate that the model has an OpenSearch index class (fails gracefully in job)

## Models Using This Concern
- `Music::Artist`
- `Music::Album` 
- `Music::Song`

## Performance Considerations
- Queue creation is fast (single database insert)
- Actual indexing is deferred to background processing
- Bulk operations benefit significantly from this approach
- Queue cleanup prevents table growth over time

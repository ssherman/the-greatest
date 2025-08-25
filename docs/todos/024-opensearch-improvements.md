# 024 - OpenSearch Improvements

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-08-23
- **Started**: 2025-08-23
- **Completed**: 2025-08-25
- **Developer**: Claude (AI Assistant)

## Overview
Improve the existing OpenSearch integration for music models by adding structured data fields for better filtering and relationships, and implement an efficient background indexing service to handle bulk operations without blocking the main application.

## Context
- Current OpenSearch implementation only indexes text fields (names/titles) for basic search
- Need structured data fields (IDs, categories) for advanced filtering and relationship queries
- Current approach of immediate indexing via after_save callbacks causes performance issues when creating hundreds/thousands of items
- Background indexing with queuing will provide better performance and reliability

## Requirements

### Index Field Enhancements
- [x] Add `artist_id` (keyword) field to album index for exact artist matching
- [x] Add `artist_id` (keyword) and `album_ids` (keyword array) fields to song index
- [x] Add `category_ids` (keyword array) field to artist, album, and song indexes
- [x] Update `as_indexed_json` methods in music models to include new fields
- [x] Update index definitions with proper keyword mappings

### Background Indexing Service
- [x] Create `SearchIndexRequest` model with polymorphic association pattern
- [x] Add Redis service to docker-compose.yml for Sidekiq
- [x] Create Sidekiq cron job to process indexing queue every 30 seconds
- [x] Implement bulk indexing and unindexing logic that groups requests by type
- [x] Add `bulk_unindex` method to base index class for efficient bulk deletions
- [x] Create `SearchIndexable` concern for standardized indexing callbacks
- [x] Include `SearchIndexable` concern in music models that support search
- [x] Handle index/unindex operations through the queue system

## Technical Approach

### Database Schema
```ruby
# SearchIndexRequest model
class SearchIndexRequest < ApplicationRecord
  belongs_to :parent, polymorphic: true
  
  # Fields:
  # - parent_type (string) - e.g., "Music::Artist", "Music::Album", "Music::Song"  
  # - parent_id (bigint) - ID of the model to index
  # - action (enum) - :index or :unindex
  # - created_at - for processing order
end
```

### Enhanced Index Mappings

**Artist Index** (add to existing):
```ruby
category_ids: {
  type: "keyword"
}
```

**Album Index** (add to existing):
```ruby
artist_id: {
  type: "keyword"
},
category_ids: {
  type: "keyword"
}
```

**Song Index** (add to existing):
```ruby  
artist_id: {
  type: "keyword"
},
album_ids: {
  type: "keyword"
},
category_ids: {
  type: "keyword"
}
```

### Background Processing Architecture
```ruby
# Sidekiq cron job (every 30 seconds)
class Search::IndexerJob
  include Sidekiq::Job
  
  def perform
    # Process each indexed model type
    %w[Music::Artist Music::Album Music::Song].each do |model_type|
      process_requests_for_type(model_type)
    end
  end
  
  private
  
  def process_requests_for_type(model_type)
    requests = SearchIndexRequest.where(parent_type: model_type)
                                .order(:created_at)
                                .limit(1000)
    
    return if requests.empty?
    
    # Group by action and bulk process
    index_requests = requests.select { |r| r.action == 'index' }
    unindex_requests = requests.select { |r| r.action == 'unindex' }
    
    index_class = "Search::Music::#{model_type.demodulize}Index".constantize
    
    # Bulk index
    if index_requests.any?
      models = model_type.constantize.where(id: index_requests.map(&:parent_id))
      index_class.bulk_index(models)
    end
    
    # Bulk unindex - now using efficient bulk operation!
    if unindex_requests.any?
      item_ids = unindex_requests.map(&:parent_id)
      index_class.bulk_unindex(item_ids)  # Single bulk operation instead of individual deletes
    end
    
    # Clean up processed requests
    requests.delete_all
  end
end
```

### Base Index Class Enhancement
```ruby
# Add to Search::Base::Index class
def self.bulk_unindex(item_ids)
  return if item_ids.empty?

  actions = []
  item_ids.each do |item_id|
    actions << {
      delete: { _index: index_name, _id: item_id }
    }
  end

  response = client.bulk(body: actions, refresh: true)

  if response["errors"]
    response["items"].each do |item|
      if item["delete"]["error"]
        Rails.logger.error "Failed to unindex item ID #{item["delete"]["_id"]}: #{item["delete"]["error"]}"
      end
    end
  else
    Rails.logger.info "Successfully unindexed batch of #{item_ids.size} items from '#{index_name}'"
  end

  response
end
```

### SearchIndexable Concern
```ruby
# app/models/concerns/search_indexable.rb
module SearchIndexable
  extend ActiveSupport::Concern

  included do
    after_save :queue_for_indexing
    after_destroy :queue_for_unindexing
  end

  private

  def queue_for_indexing
    SearchIndexRequest.create!(parent: self, action: :index)
  end

  def queue_for_unindexing  
    SearchIndexRequest.create!(parent: self, action: :unindex)
  end
end
```

### Model Integration
```ruby
# Simply include the concern in searchable models
class Music::Artist < ApplicationRecord
  include SearchIndexable
  # ... rest of model
end

class Music::Album < ApplicationRecord
  include SearchIndexable
  # ... rest of model
end

class Music::Song < ApplicationRecord
  include SearchIndexable
  # ... rest of model
end
```

## Dependencies
- Existing OpenSearch integration (Search::Base::Index and music index classes)
- Sidekiq gem (already added)
- sidekiq-cron gem for scheduled jobs
- Redis service for Sidekiq
- Music models with category associations (already implemented)

## Acceptance Criteria
- [x] Album index includes `artist_id` field for exact artist filtering
- [x] Song index includes `artist_id` and `album_ids` fields for relationship queries
- [x] All music indexes include `category_ids` field for category filtering
- [x] SearchIndexRequest model handles polymorphic queuing of index operations
- [x] Redis service runs in Docker development environment
- [x] Sidekiq cron job processes indexing queue every 30 seconds
- [x] Bulk indexing and unindexing operations group requests by model type for efficiency
- [x] Base index class includes `bulk_unindex` method for efficient bulk deletions
- [x] SearchIndexable concern provides standardized indexing callbacks
- [x] After_save callbacks queue indexing without blocking main thread
- [x] All existing OpenSearch functionality continues to work
- [x] Performance improvement measurable when creating large batches of items

## Design Decisions
- **Keyword fields for IDs**: Use keyword type for exact matching on ID fields
- **Array keywords for relationships**: Songs can belong to multiple albums, use array
- **Polymorphic queue pattern**: Follows Rails conventions for flexible model associations
- **30-second processing interval**: Balance between responsiveness and resource usage
- **Bulk operations**: Group requests by type to leverage existing bulk_index methods and new bulk_unindex method
- **Queue cleanup**: Remove processed requests to prevent table growth
- **Action enum**: Support both index and unindex operations through same queue
- **Concern pattern**: Use SearchIndexable concern for DRY, consistent indexing behavior across models

## Future Enhancements
- Add priority levels to indexing queue (high/normal/low)
- Implement retry logic for failed indexing operations
- Add monitoring and metrics for indexing performance
- Consider real-time indexing for critical updates
- Extend to other media types (books, movies, games)

---

## Implementation Notes

### Approach Taken
Successfully implemented a comprehensive background indexing system using Sidekiq and Redis. The implementation followed a queue-based approach where model changes trigger `SearchIndexRequest` records, which are then processed in bulk by a scheduled Sidekiq job every 30 seconds.

### Key Files Changed
- `web-app/app/lib/search/base/index.rb` - Added `bulk_unindex` method
- `web-app/app/lib/search/music/artist_index.rb` - Added `category_ids` field mapping
- `web-app/app/lib/search/music/album_index.rb` - Added `artist_id` and `category_ids` field mappings
- `web-app/app/lib/search/music/song_index.rb` - Added `artist_id`, `album_ids`, and `category_ids` field mappings
- `web-app/app/models/music/artist.rb` - Included `SearchIndexable` concern, updated `as_indexed_json`
- `web-app/app/models/music/album.rb` - Included `SearchIndexable` concern, updated `as_indexed_json`
- `web-app/app/models/music/song.rb` - Included `SearchIndexable` concern, updated `as_indexed_json`
- `docker-compose.yml` - Added Redis service
- `web-app/app/models/search_index_request.rb` - Created polymorphic queue model
- `web-app/db/migrate/20250823054414_create_search_index_requests.rb` - Database migration
- `web-app/app/models/concerns/search_indexable.rb` - Reusable concern for indexing callbacks
- `web-app/app/models/category_item.rb` - Added callbacks to trigger reindexing when categories change
- `web-app/app/sidekiq/search/indexer_job.rb` - Main background processing job
- `web-app/config/schedule.yml` - Sidekiq-cron configuration
- `web-app/config/initializers/sidekiq.rb` - Sidekiq Redis configuration
- `web-app/config/routes.rb` - Added Sidekiq Web UI
- `web-app/app/models/music/release.rb` - Added `dependent: :nullify` to prevent foreign key violations
- Comprehensive test files for all new functionality

### Challenges Encountered
1. **Enum Naming Conflict**: `SearchIndexRequest` initially used `index` as an enum value, which conflicted with ActiveRecord's `index` method. Resolved by renaming to `index_item` and `unindex_item`.

2. **`as_indexed_json` Category IDs**: Initial implementation referenced undefined `category_ids` method. Fixed by using `categories.active.pluck(:id)` to fetch active category IDs.

3. **Callback Timing**: Initially used `after_commit` callbacks but switched to `after_save`/`after_destroy` for better test compatibility while maintaining production safety.

4. **Foreign Key Violations**: Album destruction caused foreign key violations in `music_song_relationships`. Fixed by adding `dependent: :nullify` to `Music::Release` associations.

5. **CategoryItem Logic**: Complex logic to prevent indexing requests when parent items were being destroyed. Simplified to always queue requests and let the job handle missing items gracefully.

6. **Test Mocking**: Sidekiq job tests required careful mocking of ActiveRecord chains and OpenSearch index classes using Mocha.

### Deviations from Plan
- **Job Framework**: Migrated from ActiveJob to pure Sidekiq job (`Search::IndexerJob`) for better control and performance
- **Deduplication Strategy**: Chose to allow duplicate `SearchIndexRequest` records and deduplicate in the job rather than preventing duplicates at creation time
- **CategoryItem Handling**: Simplified the callback logic to always queue reindexing requests rather than trying to detect parent destruction
- **Enum Values**: Changed from `index`/`unindex` to `index_item`/`unindex_item` due to naming conflicts

### Code Examples
**SearchIndexable Concern**:
```ruby
module SearchIndexable
  extend ActiveSupport::Concern

  included do
    after_save :queue_for_indexing
    after_destroy :queue_for_unindexing
  end

  private

  def queue_for_indexing
    SearchIndexRequest.create!(parent: self, action: :index_item)
  end

  def queue_for_unindexing
    SearchIndexRequest.create!(parent: self, action: :unindex_item)
  end
end
```

**Bulk Unindex Method**:
```ruby
def self.bulk_unindex(item_ids)
  return if item_ids.empty?
  actions = []
  item_ids.each do |item_id|
    actions << { delete: { _index: index_name, _id: item_id } }
  end
  response = client.bulk(body: actions, refresh: true)
  # Error handling and logging...
end
```

### Testing Approach
- Created comprehensive test suites for all new models, concerns, and jobs
- Used Mocha for mocking OpenSearch index classes in Sidekiq job tests
- Tested deduplication, error handling, and edge cases
- Verified callback behavior across create, update, and destroy operations
- Ensured proper cleanup of processed requests

### Performance Considerations
- Bulk operations process up to 1000 requests per job run to prevent memory issues
- Deduplication in job reduces redundant indexing operations
- Efficient database queries with proper indexes on `SearchIndexRequest`
- Model associations loaded only when required by index classes

### Future Improvements
- Add retry logic for failed indexing operations
- Implement priority levels for indexing queue
- Add monitoring and metrics for indexing performance
- Consider real-time indexing for critical updates
- Extend to other media types (books, movies, games)

### Lessons Learned
- **Simplicity over Complexity**: The simplified CategoryItem callback approach proved more robust than complex validation logic
- **Test-Driven Development**: Test failures consistently revealed logical flaws and led to better implementations
- **Graceful Degradation**: Allowing the job to handle missing items gracefully is more reliable than preventing edge cases
- **Enum Naming**: Be careful with enum values that might conflict with existing methods
- **Transaction Safety**: Consider callback timing carefully for production vs test environments

### Related PRs
*No PRs created - implemented directly in development environment*

### Documentation Updated
- [x] Updated OpenSearch improvements todo document with implementation details
- [x] Create SearchIndexRequest model documentation
- [x] Create SearchIndexable concern documentation  
- [x] Create Search::IndexerJob documentation
- [x] Update base index class documentation with bulk_unindex method
- [x] Update music model documentation with new indexing behavior
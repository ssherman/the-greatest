# 024 - OpenSearch Improvements

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-08-23
- **Started**: 
- **Completed**: 
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
- [ ] Add `artist_id` (keyword) field to album index for exact artist matching
- [ ] Add `artist_id` (keyword) and `album_ids` (keyword array) fields to song index
- [ ] Add `category_ids` (keyword array) field to artist, album, and song indexes
- [ ] Update `as_indexed_json` methods in music models to include new fields
- [ ] Update index definitions with proper keyword mappings

### Background Indexing Service
- [ ] Create `SearchIndexRequest` model with polymorphic association pattern
- [ ] Add Redis service to docker-compose.yml for Sidekiq
- [ ] Create Sidekiq cron job to process indexing queue every 30-60 seconds
- [ ] Implement bulk indexing and unindexing logic that groups requests by type
- [ ] Add `bulk_unindex` method to base index class for efficient bulk deletions
- [ ] Create `SearchIndexable` concern for standardized indexing callbacks
- [ ] Include `SearchIndexable` concern in music models that support search
- [ ] Handle index/unindex operations through the queue system

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
class Search::IndexingJob < ApplicationJob
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
- [ ] Album index includes `artist_id` field for exact artist filtering
- [ ] Song index includes `artist_id` and `album_ids` fields for relationship queries
- [ ] All music indexes include `category_ids` field for category filtering
- [ ] SearchIndexRequest model handles polymorphic queuing of index operations
- [ ] Redis service runs in Docker development environment
- [ ] Sidekiq cron job processes indexing queue every 30 seconds
- [ ] Bulk indexing and unindexing operations group requests by model type for efficiency
- [ ] Base index class includes `bulk_unindex` method for efficient bulk deletions
- [ ] SearchIndexable concern provides standardized indexing callbacks
- [ ] After_save callbacks queue indexing without blocking main thread
- [ ] All existing OpenSearch functionality continues to work
- [ ] Performance improvement measurable when creating large batches of items

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
*[To be filled out during implementation]*

### Approach Taken
*Document the actual implementation approach*

### Key Files Changed
*List all files modified during implementation*

### Challenges Encountered
*Note any unexpected issues and solutions*

### Deviations from Plan
*Document any changes from the original approach*

### Code Examples
*Include key code snippets*

### Testing Approach
*How the feature was tested*

### Performance Considerations
*Optimizations made or needed*

### Future Improvements
*Additional enhancements identified*

### Lessons Learned
*What worked well, what could be improved*

### Related PRs
*Link to any pull requests*

### Documentation Updated
- [ ] Update OpenSearch index documentation files
- [ ] Create SearchIndexRequest model documentation
- [ ] Create SearchIndexable concern documentation
- [ ] Update docker-compose.yml documentation
- [ ] Add Sidekiq job documentation
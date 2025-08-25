# SearchIndexRequest

## Summary
Queues OpenSearch indexing and unindexing operations for background processing. Core model for the background indexing system that prevents performance issues during bulk operations.

## Associations
- `belongs_to :parent, polymorphic: true` - The model to be indexed/unindexed (Music::Artist, Music::Album, Music::Song, etc.)

## Public Methods

### `.for_type(model_type)`
Scope to filter requests by parent model type
- Parameters: model_type (String) - e.g., "Music::Artist", "Music::Album"
- Returns: ActiveRecord::Relation

### `.for_action(action)`
Scope to filter requests by action type
- Parameters: action (String/Symbol) - :index_item or :unindex_item
- Returns: ActiveRecord::Relation

### `.oldest_first`
Scope to order requests by creation date (oldest first)
- Returns: ActiveRecord::Relation ordered by created_at ASC

## Validations
- `parent_type` - presence required
- `parent_id` - presence required
- `action` - inclusion in enum values (index_item, unindex_item)

## Enums
- `action` - :index_item (0), :unindex_item (1)

## Database Schema
- `parent_type` (string, not null) - Polymorphic type column
- `parent_id` (bigint, not null) - Polymorphic ID column  
- `action` (integer, not null) - Enum for index_item/unindex_item
- `created_at` (datetime) - For processing order
- `updated_at` (datetime) - Standard Rails timestamp

## Indexes
- `[:parent_type, :parent_id]` - For efficient polymorphic lookups
- `action` - For filtering by action type
- `created_at` - For oldest-first processing order

## Usage Pattern
Created automatically by the `SearchIndexable` concern when models are saved or destroyed. Processed in bulk by `Search::IndexerJob` every 30 seconds and then deleted.

## Dependencies
- Used by `SearchIndexable` concern for automatic queue population
- Processed by `Search::IndexerJob` Sidekiq job
- Supports any model that includes `SearchIndexable`

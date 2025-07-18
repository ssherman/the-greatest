# Search::Base::Index

## Summary
Base class for all OpenSearch index management. Provides common functionality for creating, managing, and interacting with OpenSearch indexes while allowing subclasses to define their own index structure and model-specific behavior.

## Public Methods

### `.client`
Returns the shared OpenSearch client instance
- Returns: OpenSearch::Client - Configured client for OpenSearch operations

### `.index_name`
Automatically derives index name from class name with environment suffix
- Returns: String - Index name (e.g., "music_artists_development_12345")
- Example: `Search::Music::ArtistIndex` → `music_artists_development`

### `.index_definition`
Abstract method that must be implemented by subclasses
- Returns: Hash - OpenSearch index mapping and settings definition
- Raises: NotImplementedError if not implemented by subclass

### `.model_klass`
Abstract method that must be implemented by subclasses
- Returns: Class - The ActiveRecord model class this index manages
- Raises: NotImplementedError if not implemented by subclass

### `.model_includes`
Optional method for specifying eager loading associations
- Returns: Array - ActiveRecord includes for eager loading (default: [])
- Override in subclasses when eager loading is needed for indexing

### `.delete_index`
Deletes the index from OpenSearch
- Returns: void
- Logs success or handles NotFound errors gracefully

### `.create_index`
Creates the index if it doesn't already exist
- Returns: void
- Automatically checks for existence to prevent conflicts
- Uses index_definition from subclass

### `.index_exists?`
Checks if the index exists in OpenSearch
- Returns: Boolean - true if index exists, false otherwise

### `.bulk_index(items)`
Efficiently indexes multiple items using OpenSearch bulk API
- Parameters: items (Array) - Collection of model instances to index
- Returns: Hash - OpenSearch bulk response
- Calls `as_indexed_json` on each item

### `.index_item(item)`
Indexes a single model instance
- Parameters: item (ActiveRecord model) - Model instance to index
- Returns: Hash - OpenSearch index response
- Calls `as_indexed_json` on the item

### `.unindex_item(item_id)`
Removes an item from the index by ID
- Parameters: item_id (Integer/String) - ID of item to remove
- Returns: void
- Handles NotFound errors gracefully

### `.find_by_id(item_id)`
Retrieves an item from the index by ID
- Parameters: item_id (Integer/String) - ID of item to find
- Returns: Hash - The indexed document source, or nil if not found

### `.refresh_index`
Forces OpenSearch to refresh the index
- Returns: void
- Useful for making recent changes visible immediately

## Standard Interface Methods

### `.index(model)`
Indexes a single model instance (standard interface)
- Parameters: model (ActiveRecord model) - Model instance to index
- Returns: Hash - OpenSearch index response
- Delegates to `index_item`

### `.unindex(model)`
Removes a model instance from index (standard interface)
- Parameters: model (ActiveRecord model) - Model instance to remove
- Returns: void
- Delegates to `unindex_item(model.id)`

### `.find(id)`
Finds a model in the index by ID (standard interface)
- Parameters: id (Integer/String) - ID of model to find
- Returns: Hash - The indexed document source, or nil if not found
- Delegates to `find_by_id`

### `.reindex_all`
Reindexes all models for this index type (standard interface)
- Returns: void
- Deletes and recreates index, then bulk indexes all models
- Uses `model_klass` and `model_includes` for efficient querying
- Processes in batches of 1000 for memory efficiency

## Constants
None

## Dependencies
- OpenSearch::Client - For all OpenSearch operations
- Rails.logger - For logging operations
- ActiveRecord - For model querying and batch processing

## Usage Pattern
Subclasses must implement:
1. `model_klass` - Return the ActiveRecord model class
2. `index_definition` - Return the OpenSearch mapping definition
3. `model_includes` (optional) - Return eager loading associations

Example subclass:
```ruby
class Search::Music::ArtistIndex < Search::Base::Index
  def self.model_klass
    ::Music::Artist
  end

  def self.index_definition
    {
      settings: { ... },
      mappings: { ... }
    }
  end
end
```

## Private Methods
- `derive_index_name_from_class` - Converts class name to index name with environment suffix 
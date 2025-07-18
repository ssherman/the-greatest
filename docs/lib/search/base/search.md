# Search::Base::Search

## Summary
Base class for all OpenSearch query classes. Provides common functionality for executing searches and building query structures while allowing subclasses to define their own search logic and index targeting.

## Public Methods

### `.client`
Returns the shared OpenSearch client instance
- Returns: OpenSearch::Client - Configured client for OpenSearch operations

### `.index_name`
Abstract method that must be implemented by subclasses
- Returns: String - Name of the index to search
- Raises: NotImplementedError if not implemented by subclass

### `.search(query_definition)`
Executes a search query against OpenSearch
- Parameters: query_definition (Hash) - Complete OpenSearch query structure
- Returns: Array - Formatted search results with :id, :score, and :source keys
- Handles connection errors gracefully by returning empty array

### `.build_multi_match_query(query, fields, boost_values = {})`
Builds a multi-match query across multiple fields with different boost values
- Parameters: 
  - query (String) - Search text
  - fields (Array) - Field names to search
  - boost_values (Hash) - Boost values for exact, phrase, and fuzzy matching
- Returns: Hash - OpenSearch multi-match query structure
- Uses "most_fields" type for comprehensive matching

### `.build_query_definition(query_structure, options = {})`
Builds a complete query definition with common options
- Parameters:
  - query_structure (Hash) - The main query structure
  - options (Hash) - Additional options (min_score, size, from)
- Returns: Hash - Complete OpenSearch query definition
- Applies min_score filtering and pagination

## Constants
None

## Dependencies
- OpenSearch::Client - For executing search queries
- Search::Shared::Utils - For query building utilities
- Rails.logger - For logging search operations

## Usage Pattern
Subclasses must implement:
1. `index_name` - Return the name of the index to search

Example subclass:
```ruby
class Search::Music::Search::ArtistGeneral < Search::Base::Search
  def self.index_name
    ::Search::Music::ArtistIndex.index_name
  end

  def self.call(text, options = {})
    # Build query and call search(query_definition)
  end
end
```

## Private Methods
- `default_analyzer` - Returns the default text analyzer ("folding")
- `default_boost_values` - Returns default boost values for different match types
- `apply_min_score` - Applies minimum score filtering to query
- `apply_size_and_from` - Applies pagination parameters to query 
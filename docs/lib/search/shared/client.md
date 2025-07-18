# Search::Shared::Client

## Summary
Centralized OpenSearch client management for the search system. Provides a singleton-like pattern for sharing OpenSearch client instances across all search operations.

## Public Methods

### `.instance`
Returns the shared OpenSearch client instance
- Returns: OpenSearch::Client - Configured client instance
- Creates client on first access using OPENSEARCH_URL environment variable
- Thread-safe singleton implementation

### `.ping`
Tests connectivity to OpenSearch server
- Returns: Hash - OpenSearch cluster information if successful
- Raises: OpenSearch connection error if server unavailable
- Used for health checks and availability testing

## Constants
None

## Dependencies
- OpenSearch::Client - Ruby client for OpenSearch
- ENV['OPENSEARCH_URL'] - Environment variable for OpenSearch server URL

## Usage Pattern
Used throughout the search system for consistent client access:

```ruby
# In base classes
def self.client
  @client ||= Search::Shared::Client.instance
end

# For health checks
begin
  Search::Shared::Client.ping
  # OpenSearch is available
rescue => e
  # Handle connection error
end
```

## Configuration
Requires OPENSEARCH_URL environment variable:
- Development: `OPENSEARCH_URL=https://localhost:9200`
- Production: `OPENSEARCH_URL=https://search-cluster.amazonaws.com` 
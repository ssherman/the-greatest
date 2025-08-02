# DataImporters::ProviderResult

## Summary
Represents the result of a single provider's import attempt. Tracks success/failure status, data populated, and error details for individual external data sources.

## Public Methods

### `.success(provider:, data_populated: [])`
Class method to create successful result
- Parameters:
  - provider (String) - Provider class name for identification
  - data_populated (Array<Symbol>) - List of fields that were populated
- Returns: ProviderResult with success: true
- Purpose: Consistent success result creation

### `.failure(provider:, errors:)`
Class method to create failed result
- Parameters:
  - provider (String) - Provider class name for identification
  - errors (Array<String>) - List of error messages
- Returns: ProviderResult with success: false
- Purpose: Consistent failure result creation

### `#success?`
- Returns: Boolean - True if provider succeeded
- Purpose: Quick success check

### `#failure?`
- Returns: Boolean - True if provider failed
- Purpose: Inverse of success? for convenience

## Attributes
- `provider_name` (String) - Name of the provider class for identification
- `success` (Boolean) - Whether the provider operation succeeded
- `data_populated` (Array<Symbol>) - Fields that were successfully populated
- `errors` (Array<String>) - Error messages if operation failed

## Usage Patterns

### Creating Success Results
```ruby
# In a provider class
def populate(artist, query:)
  # ... fetch and populate data ...
  
  success_result(data_populated: [:name, :kind, :country, :musicbrainz_id])
end
```

### Creating Failure Results
```ruby
# In a provider class
def populate(artist, query:)
  search_result = api_client.search(query.name)
  return failure_result(errors: ["Network timeout"]) unless search_result.success?
  
  # ... continue processing ...
rescue => e
  failure_result(errors: ["API error: #{e.message}"])
end
```

### Analyzing Results
```ruby
provider_results.each do |result|
  if result.success?
    puts "#{result.provider_name}: populated #{result.data_populated.join(', ')}"
  else
    puts "#{result.provider_name}: failed - #{result.errors.join(', ')}"
  end
end
```

## Data Population Tracking
The `data_populated` array tracks which fields were successfully populated by this provider. This allows:
- Detailed reporting of what each provider contributed
- Debugging when data is missing or incorrect
- Analytics on provider effectiveness

Common field names:
- `:name` - Basic entity name
- `:kind` - Entity type/classification
- `:country` - Geographic information
- `:life_span_data` - Date information
- `:musicbrainz_id` - External identifier
- `:isni` - International identifier

## Error Reporting
Errors should be descriptive and actionable:
- Include API response codes when relevant
- Mention specific fields that failed validation
- Provide context about what operation was attempted

## Array Handling
Both `data_populated` and `errors` are automatically converted to arrays:
- Single values become single-element arrays
- Nil values become empty arrays
- Arrays are passed through unchanged

## Dependencies
Used by ImporterBase and consumed by ImportResult for aggregated reporting.
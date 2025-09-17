# DataImporters::ProviderResult

## Summary
Represents the result of a single provider's import attempt. Standardized response object used by all providers to communicate success/failure status and detailed feedback.

## Public Methods

### `.success(provider:, data_populated: [])`
Creates a successful provider result
- Parameters:
  - provider (String) - Provider class name
  - data_populated (Array, optional) - List of fields/attributes that were populated
- Returns: ProviderResult instance with success: true

### `.failure(provider:, errors:)`
Creates a failed provider result
- Parameters:
  - provider (String) - Provider class name
  - errors (String|Array) - Error messages describing what went wrong
- Returns: ProviderResult instance with success: false

### `#success?`
- Returns: Boolean - true if provider execution was successful

### `#failure?`
- Returns: Boolean - true if provider execution failed

## Attributes

### `provider_name`
- Type: String
- Purpose: Name of the provider class that generated this result

### `success`
- Type: Boolean
- Purpose: Whether the provider execution succeeded

### `data_populated`
- Type: Array<String>
- Purpose: List of fields/attributes that were populated by the provider
- Usage: Helps track what data was contributed by each provider

### `errors`
- Type: Array<String>
- Purpose: Error messages if provider execution failed
- Usage: Detailed feedback for debugging and user display

## Usage Examples

### Successful Provider Result
```ruby
# From a provider's populate method
result = ProviderResult.success(
  provider: "DataImporters::Music::Artist::Providers::MusicBrainz",
  data_populated: %w[name country kind identifiers categories]
)

puts result.success?        # => true
puts result.provider_name   # => "DataImporters::Music::Artist::Providers::MusicBrainz"
puts result.data_populated  # => ["name", "country", "kind", "identifiers", "categories"]
```

### Failed Provider Result
```ruby
# From a provider's populate method when API fails
result = ProviderResult.failure(
  provider: "DataImporters::Music::Artist::Providers::MusicBrainz",
  errors: ["API rate limit exceeded", "Network timeout after 30s"]
)

puts result.failure?    # => true
puts result.errors      # => ["API rate limit exceeded", "Network timeout after 30s"]
```

### Usage in Provider Base Classes
```ruby
class MyProvider < DataImporters::ProviderBase
  def populate(item, query:)
    # Do work...
    
    if api_success
      success_result(data_populated: %w[name description])
    else
      failure_result(errors: ["API returned error: #{api_error}"])
    end
  end
end
```

## Dependencies
- No external dependencies - standalone data structure
- Used by all Provider classes
- Consumed by ImporterBase for result aggregation
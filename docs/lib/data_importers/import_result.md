# DataImporters::ImportResult

## Summary
Aggregates results from all providers for an import operation. Provides detailed feedback about what succeeded, what failed, and overall import status.

## Public Methods

### `.new(item:, provider_results:, success:)`
Constructor for creating import results
- Parameters:
  - item (ActiveRecord model) - The item that was imported/attempted
  - provider_results (Array<ProviderResult>) - Results from each provider
  - success (Boolean) - Overall import success status

### `#success?`
- Returns: Boolean - True if import succeeded
- Purpose: Quick check for overall import success

### `#failure?`
- Returns: Boolean - True if import failed
- Purpose: Inverse of success? for convenience

### `#successful_providers`
- Returns: Array<ProviderResult> - Only providers that succeeded
- Purpose: Identify which data sources contributed successfully

### `#failed_providers`
- Returns: Array<ProviderResult> - Only providers that failed
- Purpose: Identify which data sources had problems

### `#all_errors`
- Returns: Array<String> - All error messages from failed providers
- Purpose: Complete list of what went wrong during import

### `#summary`
- Returns: Hash with comprehensive import statistics
- Purpose: Detailed breakdown for logging and debugging

## Summary Hash Structure
```ruby
{
  success: true/false,
  item_saved: true/false,
  providers_run: Integer,
  providers_succeeded: Integer,
  providers_failed: Integer,
  data_populated: Array<Symbol>,  # Unique fields populated across all providers
  errors: Array<String>
}
```

## Attributes
- `item` - The ActiveRecord model that was imported
- `provider_results` - Array of ProviderResult objects
- `success` - Boolean indicating overall success

## Usage Patterns

### Success Checking
```ruby
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

if result.success?
  puts "Imported #{result.item.name}"
  puts "Data sources: #{result.successful_providers.map(&:provider_name).join(', ')}"
else
  puts "Import failed: #{result.all_errors.join(', ')}"
end
```

### Detailed Analysis
```ruby
summary = result.summary
puts "Providers run: #{summary[:providers_run]}"
puts "Success rate: #{summary[:providers_succeeded]}/#{summary[:providers_run]}"
puts "Fields populated: #{summary[:data_populated].join(', ')}"
```

## Success Criteria
Import is considered successful if:
1. At least one provider succeeded
2. The final item passed validation
3. The item was successfully saved to database

## Error Aggregation
Errors from all failed providers are collected and deduplicated. This provides complete visibility into what went wrong during the import process.

## Dependencies
- ProviderResult objects for individual provider feedback
- ActiveRecord models with persisted? method for save status checking
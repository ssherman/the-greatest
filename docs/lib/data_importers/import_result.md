# DataImporters::ImportResult

## Summary
Aggregated results from all providers for an import operation. Contains the final item and comprehensive feedback about provider execution, success/failure status, and detailed error reporting.

## Attributes

### `item`
- Type: ActiveRecord model or nil
- Purpose: The imported item (Music::Artist, Music::Album, etc.) or nil for multi-item imports

### `provider_results`
- Type: Array<ProviderResult>
- Purpose: Results from each provider that was executed

### `success`
- Type: Boolean
- Purpose: Overall success status of the import operation

## Public Methods

### `#success?`
- Returns: Boolean - true if the overall import operation succeeded

### `#failure?`
- Returns: Boolean - true if the overall import operation failed

### `#successful_providers`
- Returns: Array<ProviderResult> - Provider results that succeeded

### `#failed_providers`
- Returns: Array<ProviderResult> - Provider results that failed

### `#all_errors`
- Returns: Array<String> - All error messages from failed providers

### `#summary`
- Returns: Hash - Comprehensive summary of the import operation
- Hash structure:
  ```ruby
  {
    success: Boolean,
    item_saved: Boolean,
    providers_run: Integer,
    providers_succeeded: Integer,
    providers_failed: Integer,
    data_populated: Array<String>,
    errors: Array<String>
  }
  ```

## Usage Examples

### Checking Import Success
```ruby
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

if result.success?
  puts "Import succeeded!"
  puts "Artist: #{result.item.name}"
  puts "Data populated: #{result.summary[:data_populated].join(', ')}"
else
  puts "Import failed!"
  puts "Errors: #{result.all_errors.join(', ')}"
end
```

### Analyzing Provider Results
```ruby
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

puts "Providers run: #{result.provider_results.count}"
puts "Successful: #{result.successful_providers.count}"
puts "Failed: #{result.failed_providers.count}"

result.successful_providers.each do |provider|
  puts "✅ #{provider.provider_name}: #{provider.data_populated.join(', ')}"
end

result.failed_providers.each do |provider|
  puts "❌ #{provider.provider_name}: #{provider.errors.join(', ')}"
end
```

### Using Summary for Monitoring
```ruby
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")
summary = result.summary

# Log structured data for monitoring
Rails.logger.info "Import completed", summary

# Example summary output:
# {
#   success: true,
#   item_saved: true,
#   providers_run: 2,
#   providers_succeeded: 2,
#   providers_failed: 0,
#   data_populated: ["name", "country", "kind", "identifiers", "categories"],
#   errors: []
# }
```

## Dependencies
- ProviderResult class for individual provider feedback
- ActiveRecord models for item persistence checking
- Created and returned by ImporterBase implementations
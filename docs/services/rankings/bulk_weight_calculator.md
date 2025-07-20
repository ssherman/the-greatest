# Rankings::BulkWeightCalculator

## Summary
Service for bulk calculation of weights for all ranked lists within a ranking configuration. Processes multiple lists efficiently with error handling, transaction safety, and detailed result tracking.

## Associations
- None (service object, not a model)

## Public Methods

### `#initialize(ranking_configuration)`
Creates a new bulk weight calculator for the specified ranking configuration.
- Parameters: ranking_configuration (RankingConfiguration) - the configuration containing lists to process

### `#call`
Processes all ranked lists in the configuration and calculates their weights.
- Returns: Hash - detailed results of the bulk operation
- Result structure:
  ```ruby
  {
    processed: Integer,           # Total ranked lists processed
    updated: Integer,            # Lists with weight changes
    errors: Array,               # Error details for failed calculations
    weights_calculated: Array    # Details of successful calculations
  }
  ```
- Side effects: Updates weight values in database, logs results

### `#call_for_ids(ranked_list_ids)`
Processes only the specified ranked lists instead of all lists in the configuration.
- Parameters: ranked_list_ids (Array<Integer>) - specific ranked list IDs to process
- Returns: Hash - same structure as `#call`
- Useful for: Partial updates, reprocessing specific lists, testing

## Private Methods

### `#process_ranked_lists(scope)`
Core processing logic that handles the actual weight calculation for a scope of ranked lists.
- Parameters: scope (ActiveRecord::Relation) - the ranked lists to process
- Returns: Hash - processing results
- Features:
  - Uses database transaction for data consistency
  - Processes in batches for memory efficiency (`find_in_batches`)
  - Individual error handling per ranked list
  - Tracks weight changes and unchanged lists

### `#process_single_ranked_list(ranked_list, results)`
Processes a single ranked list and updates the results hash.
- Parameters: ranked_list (RankedList), results (Hash)
- Side effects: Modifies results hash with calculation outcome
- Error handling: Catches exceptions and records in errors array

### `#log_results(results)`
Logs the final processing results at appropriate log levels.
- Parameters: results (Hash) - the processing results to log
- Logs errors at ERROR level, summary at INFO level

## Validations
None (service object)

## Scopes
None (service object)

## Constants
None

## Callbacks
None (service object)

## Dependencies
- RankingConfiguration model
- RankedList model  
- WeightCalculator service classes
- Rails logger
- ActiveRecord transactions

## Error Handling

### Individual List Errors
When a single ranked list fails to calculate:
- Error is caught and logged
- Processing continues for remaining lists
- Failed list details recorded in results[:errors]
- Error entry structure:
  ```ruby
  {
    ranked_list_id: Integer,
    list_name: String,
    error: String
  }
  ```

### Transaction Safety
- All weight updates occur within a database transaction
- If critical errors occur, all changes are rolled back
- Ensures data consistency across bulk operations

## Performance Considerations

### Batch Processing
- Uses `find_in_batches` to process large numbers of ranked lists
- Prevents memory issues with configurations containing many lists
- Default batch size leverages Rails defaults

### Database Efficiency
- Uses `includes(:list)` to avoid N+1 queries
- Single transaction for all updates
- Minimal database calls per ranked list

## Usage Examples

```ruby
# Process all ranked lists in a configuration
bulk_calculator = Rankings::BulkWeightCalculator.new(ranking_configuration)
results = bulk_calculator.call

# Check results
puts "Processed: #{results[:processed]}"
puts "Updated: #{results[:updated]}"
puts "Errors: #{results[:errors].count}"

# Process specific ranked lists only
specific_ids = [1, 2, 3]
results = bulk_calculator.call_for_ids(specific_ids)

# Handle errors
results[:errors].each do |error|
  puts "Failed to process list #{error[:list_name]}: #{error[:error]}"
end

# Review weight changes
results[:weights_calculated].each do |calc|
  puts "List #{calc[:list_name]}: #{calc[:old_weight]} → #{calc[:new_weight]}"
end
```

## Logging Output

### Successful Processing
```
INFO: Bulk weight calculation completed for Configuration 'Global Books': 15 processed, 12 updated, 0 errors
```

### With Errors
```
ERROR: Failed to calculate weight for ranked list 42 (Test List): Penalty calculation error
INFO: Bulk weight calculation completed for Configuration 'Global Books': 14 processed, 11 updated, 1 errors
```

## Integration Points
- Called by ranking configuration management interfaces
- Used in background jobs for large-scale recalculations  
- Invoked after penalty configuration changes
- Used for data migration and bulk updates 
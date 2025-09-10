# BulkCalculateWeightsJob

## Summary
Sidekiq background job that performs bulk weight calculations for all ranked lists within a specific ranking configuration. Orchestrates the `Rankings::BulkWeightCalculator` service for efficient processing of large datasets.

## Purpose
- Process weight calculations in the background to avoid blocking user requests
- Handle bulk recalculation of weights when penalty configurations change
- Provide detailed logging and error handling for weight calculation processes
- Triggered by AVO admin action for bulk weight recalculation

## Parameters

### `#perform(ranking_configuration_id)`
- **ranking_configuration_id** (Integer) - ID of the RankingConfiguration to process
- Raises: `ActiveRecord::RecordNotFound` if ranking configuration doesn't exist

## Process Flow
1. **Find Configuration**: Locates the RankingConfiguration by ID
2. **Initialize Calculator**: Creates `Rankings::BulkWeightCalculator` instance
3. **Execute Calculation**: Calls calculator to process all ranked lists
4. **Log Results**: Records processing statistics and any errors
5. **Return Results**: Returns the calculator results hash

## Return Value
Returns a hash from `Rankings::BulkWeightCalculator#call`:
```ruby
{
  processed: Integer,  # Number of ranked lists processed
  updated: Integer,    # Number of lists with weight changes
  errors: Array,       # Array of error hashes for failed calculations
  weights_calculated: Array  # Details of weight changes (when applicable)
}
```

## Error Handling
- **ActiveRecord::RecordNotFound**: Re-raised after logging when ranking configuration doesn't exist
- **StandardError**: All other exceptions are logged with full backtrace and re-raised
- **Calculator Errors**: Individual list calculation errors are captured in results[:errors] array

## Logging
- **Info Level**: Start/completion messages with configuration details and result statistics
- **Error Level**: Individual calculation errors and job-level exceptions
- **Detailed Results**: Logs processed count, updated count, and error count

## Dependencies
- `RankingConfiguration` model - Target configuration to process
- `Rankings::BulkWeightCalculator` - Core calculation service
- Sidekiq - Job processing framework
- Rails.logger - Logging infrastructure

## Usage Examples

### Manual Execution
```ruby
# Enqueue job for specific configuration
BulkCalculateWeightsJob.perform_async(ranking_config.id)

# Synchronous execution (for testing)
job = BulkCalculateWeightsJob.new
results = job.perform(ranking_config.id)
```

### Via AVO Action
The job is typically triggered through the AVO admin interface:
1. Navigate to Ranking Configurations
2. Select configuration(s)
3. Choose "Recalculate List Weights" action
4. Job is enqueued automatically

## Performance Considerations
- **Database Transactions**: Calculator uses transactions for consistency
- **Memory Usage**: Processes lists in batches via `find_each`
- **Background Processing**: Runs asynchronously to avoid blocking requests
- **Parallel Jobs**: Multiple configurations can be processed simultaneously

## Monitoring
- **Sidekiq Dashboard**: Monitor job status, retries, and failures
- **Rails Logs**: Detailed processing information and error details
- **Result Statistics**: Track processing efficiency and error rates

## Related Classes
- `Rankings::BulkWeightCalculator` - Core calculation logic
- `Rankings::WeightCalculator` - Individual weight calculation
- `Avo::Actions::RankingConfigurations::BulkCalculateWeights` - AVO admin action
- `RankingConfiguration` - Target model for processing
- `RankedList` - Individual list records that get weight updates

## Testing
- Unit tests verify job behavior with valid/invalid configurations
- Integration tests ensure proper calculator interaction
- Error handling tests confirm appropriate exception management
- Uses Mocha for stubbing in failure scenarios

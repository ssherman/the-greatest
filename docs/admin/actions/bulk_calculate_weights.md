# Avo::Actions::RankingConfigurations::BulkCalculateWeights

## Summary
AVO admin action that allows bulk recalculation of weights for all ranked lists within selected ranking configurations. Enqueues background jobs for processing to handle large datasets efficiently.

## Usage
Available in AVO admin interface on RankingConfiguration resources. Can be applied to single configurations or multiple selected configurations.

## Process Flow
1. **Validation** - Ensures selected records are RankingConfiguration instances
2. **Job Enqueueing** - Creates separate background job for each valid configuration
3. **User Feedback** - Returns success message with count of enqueued jobs

## Parameters
- `query` - AVO query object containing selected ranking configuration records
- `fields` - Form fields (unused)
- `current_user` - Current admin user (unused)
- `resource` - AVO resource context (unused)

## Return Values
- **Success** - `succeed "X ranking configuration(s) queued for weight recalculation..."`
- **Error** - `error "Invalid record types found. This action can only be used on Ranking Configurations."`

## Background Processing
Each valid configuration triggers `BulkCalculateWeightsJob.perform_async(config_id)` which:
1. Finds the ranking configuration by ID
2. Creates `Rankings::BulkWeightCalculator.new(ranking_configuration)`
3. Calls `calculator.call` to process all ranked lists
4. Logs detailed results including processed count, updated count, and any errors

## Error Handling
- Invalid record types are logged and rejected
- Returns user-friendly error if no valid configurations found
- Individual job failures handled by Sidekiq retry mechanism
- Comprehensive logging of processing results and errors

## Configuration
```ruby
self.name = "Recalculate List Weights"
self.message = "This will recalculate weights for all ranked lists in the selected ranking configuration(s) in the background. This may take several minutes for configurations with many lists."
self.confirm_button_label = "Recalculate Weights"
```

## Admin Interface Location
- Available on: `Avo::Resources::RankingConfiguration`
- Appears as: Bulk action in index view and single action in show view
- Works with: Any RankingConfiguration record

## Performance Considerations
- Each configuration processed in separate background job for parallel execution
- Uses database transactions within BulkWeightCalculator for consistency
- Logs progress and results for monitoring
- Suitable for configurations with hundreds or thousands of ranked lists

## Dependencies
- `RankingConfiguration` model
- `BulkCalculateWeightsJob` background job
- `Rankings::BulkWeightCalculator` service class
- Sidekiq for job processing
- AVO framework for admin interface

## Usage Examples

### Single Configuration Weight Recalculation
1. Navigate to Ranking Configurations in AVO admin
2. Open specific configuration record
3. Click "Recalculate List Weights" action
4. Confirm recalculation
5. Monitor job progress in Sidekiq dashboard

### Bulk Recalculation
1. Navigate to Ranking Configurations index
2. Select multiple configurations
3. Choose "Recalculate List Weights" from bulk actions
4. Confirm recalculation
5. Monitor job progress for each configuration

## Monitoring
- Check Sidekiq dashboard for job status
- Review Rails logs for detailed processing results
- Look for error logs if jobs fail
- Results include counts of processed/updated lists

## Related Classes
- `BulkCalculateWeightsJob` - Background job triggered by this action
- `Rankings::BulkWeightCalculator` - Core bulk calculation logic
- `Rankings::WeightCalculator` - Individual weight calculation logic
- `RankingConfiguration` - Target configuration model
- `RankedList` - Individual list records that get weight updates

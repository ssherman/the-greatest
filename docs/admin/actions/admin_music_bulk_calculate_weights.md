# Actions::Admin::Music::BulkCalculateWeights

## Summary
Custom admin action that enqueues background jobs to recalculate weights for all ranked lists in selected ranking configurations. Visible on both index and show pages of the custom admin interface.

## Purpose
- Triggers weight recalculation for ranking configurations in custom admin (non-Avo)
- Enqueues `BulkCalculateWeightsJob` for background processing
- Prevents request timeouts by running calculations asynchronously
- Provides user feedback via success messages

## Action Metadata

### `self.name`
Returns: `"Bulk Calculate Weights"`
- Display name shown in custom admin UI

### `self.message`
Returns: `"Recalculate weights for all ranked lists in the selected configurations."`
- Description shown to users before executing

### `self.visible?(context)`
Returns: `true` if `context[:view]` is `:index` or `:show`, `false` otherwise
- Controls where action appears in custom admin interface
- Visible on both index page (bulk) and show page (single config)

## Execution

### `#call`
Enqueues weight calculation jobs for selected configurations.

**Parameters** (via initializer):
- `user` - Current admin user
- `models` - Array of RankingConfiguration instances
- `fields` - Hash of additional parameters (unused)

**Process**:
1. Validates at least one configuration selected
2. Iterates through each configuration
3. Enqueues `BulkCalculateWeightsJob.perform_async(config.id)`
4. Returns success with count of configurations queued

**Returns**:
- Success: `ActionResult` with message "Weight calculation queued for N configuration(s)."
- Error: `ActionResult` with message "No configurations selected."

## Job Delegation
Delegates to `BulkCalculateWeightsJob` which:
- Finds the RankingConfiguration
- Instantiates `Rankings::BulkWeightCalculator`
- Processes all ranked_lists for the configuration
- Logs results and errors

## UI Integration

**Index Page:**
- Button label: "Bulk Calculate Weights"
- Confirmation: "This will recalculate weights for all ranked lists in selected configurations. Continue?"
- Processes all configurations when no IDs provided

**Show Page:**
- Menu item label: "Recalculate List Weights"
- Confirmation: "Recalculate weights for all ranked lists in this configuration?"
- Processes single configuration

## Security
- Requires admin or editor role
- Only accessible from authenticated admin interface

## Performance
- Asynchronous: Returns immediately with "queued" message
- Background processing: Jobs run in Sidekiq
- No request timeout risk for large datasets

## Error Handling
- Validates models array is not empty
- Job handles missing configurations
- Individual list calculation errors logged but don't stop processing

## Related Classes
- `BulkCalculateWeightsJob` - Sidekiq job that performs the calculation
- `Rankings::BulkWeightCalculator` - Service that calculates weights
- `RankingConfiguration` - Parent model for configurations
- `RankedList` - Lists that get weight updates
- `Avo::Actions::RankingConfigurations::BulkCalculateWeights` - Original Avo action (being replaced)

## File Location
`app/lib/actions/admin/music/bulk_calculate_weights.rb`

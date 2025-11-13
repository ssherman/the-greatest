# Actions::Admin::Music::RefreshRankings

## Summary
Custom admin action that enqueues a background job to recalculate rankings for a single ranking configuration. Only visible on show pages for single-configuration operations in the custom admin interface.

## Purpose
- Triggers ranking recalculation for a single ranking configuration in custom admin (non-Avo)
- Enqueues `CalculateRankingsJob` for background processing
- Prevents request timeouts by running calculations asynchronously
- Updates ranked_items with new ranks and scores

## Action Metadata

### `self.name`
Returns: `"Refresh Rankings"`
- Display name shown in custom admin UI

### `self.message`
Returns: `"Recalculate rankings using current configuration and weights."`
- Description shown to users before executing

### `self.visible?(context)`
Returns: `true` if `context[:view]` is `:show`, `false` otherwise
- Controls where action appears in custom admin interface
- Only visible on show page (single configuration operations)

## Execution

### `#call`
Enqueues ranking calculation job for a single configuration.

**Parameters** (via initializer):
- `user` - Current admin user
- `models` - Array with exactly one RankingConfiguration instance
- `fields` - Hash of additional parameters (unused)

**Process**:
1. Validates exactly one configuration selected
2. Calls `config.calculate_rankings_async` to enqueue job
3. Returns success with configuration name

**Returns**:
- Success: `ActionResult` with message "Ranking calculation queued for [config name]."
- Error: `ActionResult` with message "This action can only be performed on a single configuration."

## Job Delegation
Delegates to `CalculateRankingsJob` via `config.calculate_rankings_async` which:
- Finds the RankingConfiguration
- Uses appropriate calculator (Albums or Songs)
- Recalculates ranks and scores for all items
- Updates or creates RankedItem records

## UI Integration

**Show Page:**
- Menu item label: "Refresh Rankings"
- Location: Actions dropdown
- Confirmation: "Recalculate rankings for this configuration?"
- Processes current configuration only

## Security
- Requires admin or editor role
- Only accessible from authenticated admin interface
- Validates single configuration to prevent bulk operations

## Performance
- Asynchronous: Returns immediately with "queued" message
- Background processing: Job runs in Sidekiq
- No request timeout risk for large datasets

## Error Handling
- Validates exactly one model selected
- Returns error if multiple configurations provided
- Job handles calculation errors and logs them

## Difference from BulkCalculateWeights
- **Purpose**: RefreshRankings recalculates final rankings; BulkCalculateWeights recalculates list weights
- **Scope**: RefreshRankings requires single config; BulkCalculateWeights supports multiple
- **Visibility**: RefreshRankings only on show; BulkCalculateWeights on both index and show
- **Job**: Uses CalculateRankingsJob; BulkCalculateWeights uses BulkCalculateWeightsJob

## Related Classes
- `CalculateRankingsJob` - Sidekiq job that performs ranking calculation
- `ItemRankings::Music::Albums::Calculator` - Calculator for album rankings
- `ItemRankings::Music::Songs::Calculator` - Calculator for song rankings
- `RankingConfiguration` - Parent model with `calculate_rankings_async` method
- `RankedItem` - Records that store calculated rankings
- `Avo::Actions::RankingConfigurations::RefreshRankings` - Original Avo action (being replaced)

## File Location
`app/lib/actions/admin/music/refresh_rankings.rb`

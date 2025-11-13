# Services::RankingConfiguration::CalculateWeights

## Summary
Service that calculates weights for all ranked lists in a ranking configuration. Wraps the `Rankings::BulkWeightCalculator` with a service-style interface.

## Purpose
- Provides service-layer wrapper for weight calculations
- Returns structured success/failure responses
- Used by admin actions (though now deprecated in favor of direct job enqueueing)

## Class Method

### `self.call(ranking_configuration)`
Calculates weights for all ranked lists in the configuration.

**Parameters**:
- `ranking_configuration` (RankingConfiguration) - The configuration to process

**Process**:
1. Creates service instance
2. Instantiates `Rankings::BulkWeightCalculator`
3. Calls calculator to process all ranked_lists
4. Returns structured result based on errors

**Returns**:
- Success: `{ success: true, message: "Successfully calculated weights for N ranked lists out of M processed." }`
- Partial Success: `{ success: false, error: "Weight calculation completed with N errors. M weights updated out of P processed." }`

## Implementation Note
This service is currently **not actively used** in the admin interface. The `BulkCalculateWeights` action now directly enqueues `BulkCalculateWeightsJob` instead of calling this service.

**Reason for Change:**
- Synchronous service calls could cause request timeouts
- Background jobs provide better user experience
- Service adds unnecessary abstraction layer

**Current Status:**
- Kept for potential future use or scripts
- Tests remain in place
- May be removed in future cleanup

## Calculator Delegation
Delegates to `Rankings::BulkWeightCalculator` which:
- Iterates through all ranked_lists
- Calculates base_weight using median voter count
- Applies dynamic penalties
- Stores details in `calculated_weight_details` JSONB
- Updates `weight` column

## Return Format

### Success Response
```ruby
{
  success: true,
  message: "Successfully calculated weights for 42 ranked lists out of 42 processed."
}
```

### Failure Response
```ruby
{
  success: false,
  error: "Weight calculation completed with 3 errors. 39 weights updated out of 42 processed."
}
```

## Related Classes
- `Rankings::BulkWeightCalculator` - Core calculation logic
- `BulkCalculateWeightsJob` - Sidekiq job that uses the calculator
- `RankingConfiguration` - Parent model
- `RankedList` - Lists that receive weight updates

## File Location
`app/lib/services/ranking_configuration/calculate_weights.rb`

# ListPenalty

## Summary
Represents the association between a list and a penalty. Allows multiple penalties to be applied to a single list, and enforces compatibility between list type and penalty media type.

## Associations
- `belongs_to :list` - The list being penalized
- `belongs_to :penalty` - The penalty being applied

## Public Methods

### `#system_wide_penalty?`
Returns true if the associated penalty is system-wide (no user)
- Returns: Boolean

### `#user_penalty?`
Returns true if the associated penalty is user-specific
- Returns: Boolean

### `#dynamic_penalty?`
Returns true if the associated penalty is dynamic
- Returns: Boolean

### `#static_penalty?`
Returns true if the associated penalty is static
- Returns: Boolean

**Note:** Penalty calculation logic has been moved to service objects (`Rankings::WeightCalculatorV1`) following "Skinny Models, Fat Services" principles. The join model only provides data relationships and compatibility validation.

## Validations
- `list_id` - presence, uniqueness scoped to penalty_id
- `penalty_id` - presence
- Custom: list and penalty must be compatible (STI type)

## Scopes
- `by_penalty_type(type)` - Filter by penalty STI type
- `system_wide_penalties` - Only system-wide penalties  
- `user_penalties` - Only user-specific penalties
- `dynamic_penalties` - Only dynamic penalties (based on penalty.dynamic_type)
- `static_penalties` - Only static penalties (no dynamic_type)

## Constants
_None defined._

## Callbacks
_None defined._

## Dependencies
- List model
- Penalty model

## Related Services
- `Rankings::WeightCalculatorV1` - Handles penalty calculations using ListPenalty associations
- `Rankings::BulkWeightCalculator` - Processes penalties for multiple lists 
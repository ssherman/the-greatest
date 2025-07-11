# ListPenalty

## Summary
Represents the association between a list and a penalty. Allows multiple penalties to be applied to a single list, and enforces compatibility between list type and penalty media type.

## Associations
- `belongs_to :list` - The list being penalized
- `belongs_to :penalty` - The penalty being applied

## Public Methods

### `#global_penalty?`
Returns true if the associated penalty is global
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

### `#calculate_penalty_value(ranking_configuration)`
Returns the penalty value for this list in a given ranking configuration
- Parameters: ranking_configuration (RankingConfiguration)
- Returns: Integer (penalty percentage)

## Validations
- `list_id` - presence, uniqueness scoped to penalty_id
- `penalty_id` - presence
- Custom: list and penalty must be compatible (media type)

## Scopes
- `by_penalty_type(type)` - Filter by penalty STI type
- `global_penalties` - Only global penalties
- `user_penalties` - Only user-specific penalties
- `dynamic_penalties` - Only dynamic penalties
- `static_penalties` - Only static penalties

## Constants
_None defined._

## Callbacks
_None defined._

## Dependencies
- List model
- Penalty model 
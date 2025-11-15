# ListPenalty

## Summary
Represents the association between a list and a penalty. Allows multiple penalties to be applied to a single list, and enforces compatibility between list type and penalty media type.

## Associations
- `belongs_to :list` - The list being penalized
- `belongs_to :penalty` - The penalty being applied

## Public Methods

### `#global_penalty?`
Returns true if the associated penalty is global (Global::Penalty type)
- Returns: Boolean
- Delegates to `penalty.global?`

### `#user_penalty?`
Returns true if the associated penalty is user-specific
- Returns: Boolean
- Delegates to `penalty.user_specific?`

### `#dynamic_penalty?`
Returns true if the associated penalty is dynamic
- Returns: Boolean
- Delegates to `penalty.dynamic?`

### `#static_penalty?`
Returns true if the associated penalty is static
- Returns: Boolean
- Delegates to `penalty.static?`

**Note:** Penalty calculation logic has been moved to service objects (`Rankings::WeightCalculatorV1`) following "Skinny Models, Fat Services" principles. The join model only provides data relationships and compatibility validation.

## Validations
- `list_id` - presence, uniqueness scoped to penalty_id
- `penalty_id` - presence
- Custom: `list_and_penalty_compatibility` - Ensures penalty STI type is compatible with list type (Global::Penalty works with any list, media-specific penalties only work with matching media type)
- Custom: `penalty_must_be_static` - Prevents dynamic penalties from being manually attached to lists (dynamic penalties are auto-applied during weight calculation)

## Scopes
- `by_penalty_type(type)` - Filter by penalty STI type
- `global_penalties` - Only global penalties (Global::Penalty type)
- `user_penalties` - Only user-specific penalties (non-Global types)
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
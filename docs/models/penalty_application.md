# PenaltyApplication

## Summary
Represents the application of a penalty to a specific ranking configuration, with a configuration-specific penalty value. Allows the same penalty to have different values in different ranking configurations.

## Associations
- `belongs_to :penalty` - The penalty being applied
- `belongs_to :ranking_configuration` - The ranking configuration this penalty is applied to

## Public Methods

### `#percentage_value`
Returns the penalty value as a percentage string (e.g., "25%")
- Returns: String

### `#high_penalty?`
Returns true if the penalty value is high (>= 25)
- Returns: Boolean

### `#low_penalty?`
Returns true if the penalty value is low (< 25)
- Returns: Boolean

### `#clone_for_inheritance(new_ranking_configuration)`
Clones this penalty application for a new ranking configuration (used when inheriting configs)
- Parameters: new_ranking_configuration (RankingConfiguration)
- Returns: PenaltyApplication (unsaved)

## Validations
- `penalty_id` - presence, uniqueness scoped to ranking_configuration_id
- `ranking_configuration_id` - presence
- `value` - presence, integer 0..100
- Custom: penalty and configuration must be compatible (media type)

## Scopes
- `by_value` - Order by value
- `high_value` - Value >= 25
- `low_value` - Value < 25

## Constants
_None defined._

## Callbacks
_None defined._

## Dependencies
- Penalty model
- RankingConfiguration model 
# PenaltyApplication

## Summary
Represents the application of a penalty to a specific ranking configuration, with a configuration-specific penalty value. Allows the same penalty to have different values in different ranking configurations.

## Associations
- `belongs_to :penalty` - The penalty being applied
- `belongs_to :ranking_configuration` - The ranking configuration this penalty is applied to

## Public Methods

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
_None defined._

## Constants
_None defined._

## Callbacks
_None defined._

## Dependencies
- Penalty model
- RankingConfiguration model 
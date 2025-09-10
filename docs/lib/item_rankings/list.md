# ItemRankings::List

## Summary
Wrapper class for weighted_list_rank gem representing a ranked list. Includes WeightedListRank::List module for algorithm compatibility.

## Associations
- Wraps database List model data for ranking algorithm
- Contains array of ItemRankings::Item objects

## Public Methods

### `#initialize(list_id, weight, items)`
Creates new list wrapper for ranking calculations
- Parameters: list_id (Integer), weight (Numeric), items (Array of ItemRankings::Item)
- Returns: ItemRankings::List instance
- Used by: Calculator services to prepare data for weighted_list_rank gem

## Validations
None - wrapper class for external gem integration

## Scopes
None - plain Ruby class

## Constants
None

## Callbacks
None

## Dependencies
- weighted_list_rank gem (includes WeightedListRank::List module)
- ItemRankings::Item for list contents
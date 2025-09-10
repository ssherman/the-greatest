# ItemRankings::Item

## Summary
Wrapper class for weighted_list_rank gem representing an item in a ranked list. Includes WeightedListRank::Item module for algorithm compatibility.

## Associations
- Wraps database item data (books, albums, movies, etc.) for ranking algorithm
- Contained within ItemRankings::List objects

## Public Methods

### `#initialize(item_id, position, score_penalty = nil)`
Creates new item wrapper for ranking calculations
- Parameters: item_id (Integer), position (Integer, 1-based), score_penalty (Float, optional 0.0-1.0)
- Returns: ItemRankings::Item instance
- Used by: Calculator services to prepare item data for weighted_list_rank gem

## Validations
None - wrapper class for external gem integration

## Scopes
None - plain Ruby class

## Constants
None

## Callbacks
None

## Dependencies
- weighted_list_rank gem (includes WeightedListRank::Item module)
- Used by ItemRankings::List for list contents
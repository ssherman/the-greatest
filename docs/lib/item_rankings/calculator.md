# ItemRankings::Calculator

## Summary
Base calculator class for item rankings. Implements the core ranking algorithm using the weighted_list_rank gem with exponential scoring strategy.

## Associations
- Operates on `RankingConfiguration` instance passed to constructor
- Creates/updates `RankedItem` records through database operations
- Processes `List` and `ListItem` associations for ranking calculations

## Public Methods

### `#call`
Performs the complete ranking calculation using weighted_list_rank gem
- Returns: ItemRankings::Calculator::Result struct
- Side effects: Updates RankedItem records in database with new ranks and scores

### `#list_type`
Abstract method to be implemented by subclasses
- Returns: String - the ActiveRecord type for lists (e.g., "Music::Albums::List")

### `#item_type`
Abstract method to be implemented by subclasses  
- Returns: String - the ActiveRecord type for items (e.g., "Music::Album")

### `#median_list_count`
Calculates median number of items across lists of this type
- Returns: Numeric median count used for algorithm normalization

## Validations
None - operates on validated RankingConfiguration data

## Scopes
None - service object, not ActiveRecord model

## Constants
- `Result` - Struct class with success?, data, errors attributes

## Callbacks
None

## Dependencies
- weighted_list_rank gem for ranking algorithm
- WeightedListRank::Strategies::Exponential for scoring strategy
- RankedItem model for persisting results
- List model for source data
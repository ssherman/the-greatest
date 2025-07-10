# RankedItem

## Summary
Represents a single ranked item (book, movie, album, song, or game) within a ranking configuration. Stores the calculated rank and score for each item as the output of the ranking algorithm. Supports all media types via a polymorphic association.

## Associations
- `belongs_to :item, polymorphic: true`  
  The ranked item (e.g., Books::Book, Movies::Movie, Music::Album, Music::Song, Games::Game).
- `belongs_to :ranking_configuration`  
  The ranking configuration this item is ranked in.

## Public Methods
_None defined beyond standard ActiveRecord methods._

## Validations
- `item_id` - uniqueness scoped to `[item_type, ranking_configuration_id]` (an item can only be ranked once per configuration)
- Custom validation: `item_type_matches_ranking_configuration` - ensures the item type matches the ranking configuration's media type (e.g., only Books::Book in Books::RankingConfiguration)

## Scopes
- `by_rank` - Orders items by ascending rank (lowest rank first)
- `by_score` - Orders items by descending score (highest score first, excludes items with nil score)

## Business Rules
- Each item can only appear once per ranking configuration
- The item type must match the ranking configuration's media type
- Rank and score are nullable and set by a background ranking service
- Supports all media types via polymorphic association

## Field Explanations
- **item_id**: Foreign key to the ranked item (polymorphic)
- **item_type**: Class name of the ranked item (e.g., 'Books::Book')
- **ranking_configuration_id**: Foreign key to the ranking configuration
- **rank**: Integer rank (nullable)
- **score**: Decimal score (nullable)
- **created_at/updated_at**: Standard Rails timestamps

## Dependencies
- `RankingConfiguration` model (for ranking_configuration_id)
- Item models for each media type (Books::Book, Movies::Movie, Music::Album, Music::Song, Games::Game)

## Design Notes
- Uses a polymorphic association to support all media types
- Uniqueness and type-matching validations ensure data integrity
- Rank and score are set by a background service, not required on creation
- Indexed for efficient queries by configuration, rank, and score

## Related Models
- `RankingConfiguration` (the configuration this item is ranked in)
- `Books::Book`, `Movies::Movie`, `Music::Album`, `Music::Song`, `Games::Game` (possible item types)

## Example Usage
```ruby
# Get all ranked items for a configuration, ordered by rank
config.ranked_items.by_rank

# Get the top 10 items by score
config.ranked_items.by_score.limit(10)

# Create a new ranked item (after ranking calculation)
RankedItem.create!(
  ranking_configuration: config,
  item: some_book,
  rank: 1,
  score: 9.87
)
``` 
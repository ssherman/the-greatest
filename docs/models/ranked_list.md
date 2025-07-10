# RankedList

## Summary
Represents the association between a list and a ranking configuration with an optional weight. This is a core component of the ranking system that determines which lists contribute to rankings and how much influence they have.

## Associations
- `belongs_to :list` - The list being ranked (uses STI for different media types)
- `belongs_to :ranking_configuration` - The ranking configuration that defines the algorithm parameters

## Public Methods

### `#weight`
Returns the weight assigned to this list in the ranking configuration
- Returns: Integer or nil (nullable weight field)

## Validations
- `list_id` - presence (required)
- `list_id` - uniqueness scoped to `ranking_configuration_id` (can only be added once per ranking configuration)
- `ranking_configuration_id` - presence (required)
- Custom validation: `list_type_matches_ranking_configuration` - ensures the list type matches the ranking configuration's media type

## Business Rules
- A list can only be associated with a ranking configuration once
- The list's media type must match the ranking configuration's media type (e.g., Books::List with Books::RankingConfiguration)
- Weight is optional and can be null initially
- Lists can be associated with multiple different ranking configurations

## Database Schema
```sql
CREATE TABLE ranked_lists (
  id bigint PRIMARY KEY,
  weight integer,
  list_id bigint NOT NULL,
  ranking_configuration_id bigint NOT NULL,
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL,
  UNIQUE(list_id, ranking_configuration_id)
);
```

## Usage Examples

```ruby
# Create a ranked list with weight
RankedList.create!(
  list: books_list,
  ranking_configuration: books_config,
  weight: 10
)

# Create a ranked list without weight (nullable)
RankedList.create!(
  list: movies_list,
  ranking_configuration: movies_config
)

# Find all lists for a ranking configuration
ranking_config.ranked_lists.includes(:list)

# Check if a list is already ranked in a configuration
ranking_config.ranked_lists.exists?(list: some_list)
```

## Type Matching Validation
The model enforces that the list type matches the ranking configuration type:

- `Books::RankingConfiguration` → requires `Books::List`
- `Movies::RankingConfiguration` → requires `Movies::List`
- `Games::RankingConfiguration` → requires `Games::List`
- `Music::RankingConfiguration` → requires `Music::List`

This ensures data integrity and prevents mixing different media types in ranking calculations.

## Dependencies
- Requires List model with STI support
- Requires RankingConfiguration model with STI support
- Both models must have proper type columns for STI functionality

## Related Models
- [List](list.md) - The base list model with STI subclasses
- [RankingConfiguration](ranking_configuration.md) - The ranking algorithm configuration
- [Books::List](books/list.md) - Books-specific list implementation
- [Movies::List](movies/list.md) - Movies-specific list implementation
- [Games::List](games/list.md) - Games-specific list implementation
- [Music::List](music/list.md) - Music-specific list implementation 
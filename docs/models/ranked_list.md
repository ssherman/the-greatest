# RankedList

## Summary
Represents the association between a list and a ranking configuration with an optional weight. This is a core component of the ranking system that determines which lists contribute to rankings and how much influence they have.

## Associations
- `belongs_to :list` - The list being ranked (uses STI for different media types)
- `belongs_to :ranking_configuration` - The ranking configuration that defines the algorithm parameters

## Attributes

### weight (integer)
The final calculated weight for this list in this ranking, ranging from the minimum weight (typically 1-10) to 100. Higher weights indicate higher quality/reliability.

### calculated_weight_details (jsonb)
Complete breakdown of the weight calculation, stored as JSON. Provides full transparency into how the weight was calculated, including all penalties applied, calculation inputs, and intermediate values. This field is populated automatically when Rankings::WeightCalculatorV1 calculates the weight.

**Structure:**
```json
{
  "calculation_version": 1,
  "timestamp": "2025-10-21T12:34:56Z",
  "base_values": {
    "base_weight": 100,
    "minimum_weight": 10,
    "high_quality_source": false
  },
  "penalties": [
    {
      "source": "static|dynamic_voter_count|dynamic_attribute|dynamic_temporal",
      "penalty_id": 123,
      "penalty_name": "Low Voter Count",
      "value": 24.3,
      "calculation": {...}
    }
  ],
  "penalty_summary": {
    "total_static_penalties": 20.0,
    "total_voter_count_penalties": 24.3,
    "total_attribute_penalties": 15.0,
    "total_temporal_penalties": 16.0,
    "total_before_quality_bonus": 75.3
  },
  "quality_bonus": {
    "applied": false,
    "reduction_factor": 0.6666666666666666,
    "penalty_before": 75.3,
    "penalty_after": 75.3
  },
  "final_calculation": {
    "total_penalty_percentage": 75.3,
    "capped_penalty_percentage": 75.3,
    "weight_after_penalty": 24.7,
    "weight_after_floor": 24.7,
    "final_weight": 25
  }
}
```

## Public Methods

### `#weight`
Returns the weight assigned to this list in the ranking configuration
- Returns: Integer or nil (nullable weight field)

### `#calculated_weight_details`
Returns the complete calculation breakdown as a Hash
- Returns: Hash or nil (nullable jsonb field)
- Access details via: `ranked_list.calculated_weight_details["penalties"]`

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
  calculated_weight_details jsonb,
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
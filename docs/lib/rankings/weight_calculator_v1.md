# Rankings::WeightCalculatorV1

## Summary
Version 1 implementation of the weight calculation algorithm. Calculates list weights based on penalty applications, dynamic penalties for voter count/attributes, and quality source bonuses.

## Associations
- None (service object, not a model)

## Public Methods

### `#initialize(ranked_list)`
Creates a new V1 weight calculator instance for the specified ranked list.
- Parameters: ranked_list (RankedList) - the ranked list to calculate weight for
- Inherits from: WeightCalculator

## Private Methods

### `#calculate_weight`
Main weight calculation algorithm implementation for V1.
- Returns: Integer - calculated weight
- Algorithm:
  1. Starts with base weight (100)
  2. Calculates total penalty percentage from all sources
  3. Applies quality source bonus (reduces penalties by 1/3 if high quality)
  4. Ensures penalty doesn't exceed 100%
  5. Applies penalty to starting weight
  6. Applies minimum weight floor
  7. Returns rounded integer

### `#calculate_total_penalty_percentage`
Aggregates penalty percentages from all sources.
- Returns: Float - total penalty percentage
- Sources:
  - Static penalties from penalty applications and list penalties
  - Dynamic voter count penalties
  - Attribute-based penalties (category/location specific, unknown data)

### `#calculate_voter_count_penalty`
Calculates penalties based on voter count relative to median.
- Returns: Float - penalty percentage
- Uses power curve calculation for lists below median voter count
- Lists with ≤ 1 voter get maximum penalty
- Lists above median voter count get no penalty

### `#calculate_voter_count_penalty_for_penalty(penalty, exponent: 2.0)`
Calculates voter count penalty for a specific penalty configuration.
- Parameters: penalty (Penalty), exponent (Float, default: 2.0)
- Returns: Float - penalty value clamped between 0 and max penalty
- Uses median voter count from ranking configuration
- Power curve formula: `max_penalty * ((1.0 - ratio)^exponent)`

### `#calculate_attribute_penalties`
Calculates penalties based on list attributes.
- Returns: Float - total attribute penalty percentage
- Includes: unknown data penalties, bias penalties, temporal coverage penalties

### `#calculate_unknown_data_penalties`
Penalties for lists with missing voter information.
- Returns: Float - penalty percentage
- Applied when: voter_names_unknown or voter_count_unknown

### `#calculate_bias_penalties`
Penalties for lists with geographic or category bias.
- Returns: Float - penalty percentage  
- Applied when: category_specific or location_specific

### `#calculate_temporal_coverage_penalty`
Calculates penalties based on temporal coverage (num_years_covered field).
- Returns: Float - total temporal penalty percentage
- Applied when: list has num_years_covered set and temporal penalties are configured

### `#calculate_temporal_coverage_penalty_for_penalty(penalty, exponent: 2.0)`
Calculates temporal coverage penalty for a specific penalty configuration.
- Parameters: penalty (Penalty), exponent (Float, default: 2.0)
- Returns: Float - penalty value clamped between 0 and max penalty
- Uses media-specific year range calculations
- Power curve formula: `max_penalty * ((1.0 - (years_covered / max_range))^exponent)`

### `#calculate_media_year_range`
Determines the maximum historical year range for the list's media type.
- Returns: Integer - total year range for the media type
- Music: Uses actual release_year data from albums and songs
- Books: Uses estimated range (~5000 years)
- Movies/Games: Uses estimated ranges with fallbacks

### `#find_penalty_value_by_dynamic_type(dynamic_type)`
Finds and sums penalty values for a specific dynamic penalty type.
- Parameters: dynamic_type (Symbol) - penalty type to look up
- Returns: Float - total penalty value for matching penalties

## Validations
None (service object)

## Scopes
None (service object)

## Constants
None

## Callbacks
None (service object)

## Dependencies
- WeightCalculator (parent class)
- Penalty model with dynamic_type enum
- PenaltyApplication model
- ListPenalty model
- RankingConfiguration with median_voter_count method

## Algorithm Details

### Penalty Sources
1. **Static Penalties**: Fixed values from PenaltyApplication and ListPenalty
2. **Voter Count Penalties**: Dynamic penalties based on median voter count
3. **Unknown Data Penalties**: For missing voter information
4. **Bias Penalties**: For category/location-specific lists
5. **Temporal Coverage Penalties**: For lists with limited time coverage (num_years_covered)

### Quality Source Bonus
High quality sources (lists marked as `high_quality_source: true`) get a 33% reduction in total penalty percentage applied after all penalties are calculated.

### Power Curve Calculation
For voter count penalties, uses the formula:
```
penalty = max_penalty * ((1.0 - (voter_count / median))^exponent)
```
Where exponent defaults to 2.0 for a quadratic curve.

### Median Voter Count
Uses `ranking_configuration.median_voter_count` to determine the baseline for voter count penalties. Lists at or above median get no voter count penalty.

## Usage Examples
```ruby
# Create calculator for a ranked list
calculator = Rankings::WeightCalculatorV1.new(ranked_list)

# Calculate weight (automatically uses V1 algorithm)
weight = calculator.call

# Weight is saved to ranked_list.weight
puts ranked_list.weight
``` 
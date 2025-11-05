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
Main weight calculation algorithm implementation for V1. Also captures detailed breakdown of the calculation and stores it in `ranked_list.calculated_weight_details`.
- Returns: Integer - calculated weight
- Side Effects: Sets `ranked_list.calculated_weight_details` with complete breakdown
- Algorithm:
  1. Starts with base weight (100)
  2. Calculates total penalty percentage from all sources (capturing details)
  3. Applies quality source bonus (reduces penalties by 1/3 if high quality)
  4. Ensures penalty doesn't exceed 100%
  5. Applies penalty to starting weight
  6. Applies minimum weight floor
  7. Stores complete calculation details in `calculated_weight_details`
  8. Returns rounded integer

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
- Applied when: voter_names_unknown, voter_count_unknown, or voter_count_estimated

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
3. **Unknown Data Penalties**: For missing voter information (voter_names_unknown, voter_count_unknown, voter_count_estimated)
4. **Bias Penalties**: For category/location-specific lists
5. **Temporal Coverage Penalties**: For lists with limited time coverage (num_years_covered)

### Voter Count Penalty Hierarchy
The calculator applies different severity levels for voter count reliability:
- **voter_count_unknown**: Most severe penalty (we have no information)
- **voter_count_estimated**: Moderate penalty (estimated from contextual information like award descriptions, historical records)
- **No penalty**: Exact voter count is known

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

## Calculation Details Capture

As of the latest version, WeightCalculatorV1 automatically captures and stores a complete breakdown of the weight calculation in `ranked_list.calculated_weight_details`. This provides full transparency into:

- All penalties applied (with IDs, names, values)
- Dynamic penalty calculation inputs (voter counts, ratios, formulas)
- Quality bonus application
- All intermediate calculation steps
- Final weight derivation

The details are stored as JSONB and include:
- `calculation_version`: Algorithm version (1)
- `timestamp`: When the calculation was performed
- `base_values`: Base weight, minimum weight, high quality source flag
- `penalties`: Array of all penalties with full details
- `penalty_summary`: Totals by penalty type
- `quality_bonus`: Whether and how quality bonus was applied
- `final_calculation`: All final steps (capping, flooring, rounding)

### Details Capture Methods

These private methods build the calculation details:

- `build_base_values`: Captures base weight, minimum weight, and high quality flag
- `calculate_static_penalties_with_details(details)`: Captures static penalties and appends to details
- `calculate_voter_count_penalty_with_details(details)`: Captures voter penalties with calculation inputs
- `calculate_attribute_penalties_with_details(details)`: Captures attribute penalties
- `apply_quality_bonus_with_details(penalty)`: Returns quality bonus application details
- `build_final_calculation(starting_weight, penalty_percentage)`: Returns final calculation steps

## Usage Examples
```ruby
# Create calculator for a ranked list
calculator = Rankings::WeightCalculatorV1.new(ranked_list)

# Calculate weight (automatically uses V1 algorithm and captures details)
weight = calculator.call

# Weight and details are saved to ranked_list
puts ranked_list.weight  # => 75
puts ranked_list.calculated_weight_details["penalty_summary"]
# => {"total_static_penalties"=>20.0, "total_voter_count_penalties"=>5.0, ...}

# Access penalty details
ranked_list.calculated_weight_details["penalties"].each do |penalty|
  puts "#{penalty['penalty_name']}: #{penalty['value']}%"
end

# Check if quality bonus was applied
if ranked_list.calculated_weight_details["quality_bonus"]["applied"]
  puts "High quality source bonus reduced penalties"
end
``` 
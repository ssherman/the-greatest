# Rankings::WeightCalculator

## Summary
Base class for weight calculation services in ranking configurations. Provides version-aware weight calculation factory methods and common functionality for all weight calculator implementations.

## Associations
- None (service object, not a model)

## Public Methods

### `.for_version(version)`
Factory method that returns the appropriate calculator class for the given algorithm version.
- Parameters: version (Integer) - algorithm version number  
- Returns: Class - specific calculator class (e.g., WeightCalculatorV1)
- Raises: ArgumentError for unsupported versions

### `.for_ranked_list(ranked_list)`
Convenience factory method that creates a calculator instance for a ranked list using its ranking configuration's algorithm version.
- Parameters: ranked_list (RankedList) - the ranked list to calculate weight for
- Returns: WeightCalculator instance - appropriate version calculator

### `#initialize(ranked_list)`
Creates a new weight calculator instance for the specified ranked list.
- Parameters: ranked_list (RankedList) - the ranked list to calculate weight for

### `#call`
Main entry point that calculates and saves the weight for the ranked list.
- Returns: Integer - the calculated weight
- Side effects: Updates the ranked_list.weight attribute and saves to database

### `#base_weight`
Returns the base starting weight before penalties are applied.
- Returns: Integer - default 100, can be overridden in subclasses

### `#minimum_weight`
Returns the minimum allowed weight (floor value).
- Returns: Integer - from ranking_configuration.min_list_weight

## Protected Methods

### `#calculate_weight`
Abstract method that must be implemented by subclasses to perform the actual weight calculation logic.
- Returns: Integer - calculated weight
- Raises: NotImplementedError in base class

### `#list`
Convenience accessor for the list associated with the ranked list.
- Returns: List - the list being weighted

### `#ranking_configuration`
Convenience accessor for the ranking configuration.
- Returns: RankingConfiguration - the configuration containing algorithm parameters

## Validations
None (service object)

## Scopes
None (service object)

## Constants
None

## Callbacks
None (service object)

## Dependencies
- RankedList model
- RankingConfiguration model
- Version-specific calculator classes (WeightCalculatorV1, etc.)

## Usage Examples
```ruby
# Get calculator for specific version
calculator_class = Rankings::WeightCalculator.for_version(1)
calculator = calculator_class.new(ranked_list)

# Or use convenience method
calculator = Rankings::WeightCalculator.for_ranked_list(ranked_list)

# Calculate and save weight
weight = calculator.call
```

## Design Pattern
Uses the Strategy pattern with a Factory method to enable algorithm versioning and backward compatibility as weight calculation logic evolves over time. 
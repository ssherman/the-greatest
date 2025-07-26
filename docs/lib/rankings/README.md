# Rankings Services

This directory contains service objects related to the ranking and weight calculation system for The Greatest project.

## Overview

The ranking system calculates weights for lists within ranking configurations to determine their influence on overall rankings. The system uses a versioned approach to support algorithm evolution and backward compatibility.

## Services

### [WeightCalculator](weight_calculator.md)
Base class that provides version-aware weight calculation factory methods. Uses the Strategy pattern to delegate to version-specific implementations.

**Key Features:**
- Factory methods for version selection
- Common interface for all calculators
- Automatic version detection from ranking configurations

### [WeightCalculatorV1](weight_calculator_v1.md)  
Version 1 implementation of the weight calculation algorithm. Handles penalty applications, dynamic voter count penalties, and quality source bonuses.

**Key Features:**
- Penalty aggregation from multiple sources
- Dynamic voter count penalties using power curves
- Median-based penalty calculations
- Quality source bonus application
- Attribute-based penalties (bias, unknown data)

### [BulkWeightCalculator](bulk_weight_calculator.md)
Service for processing multiple ranked lists efficiently with error handling and transaction safety.

**Key Features:**
- Batch processing with memory efficiency
- Individual error handling per list
- Transaction safety for data consistency
- Detailed result tracking and logging
- Partial processing support

## Architecture

### Version Strategy
The system uses algorithm versioning to support:
- Backward compatibility as algorithms improve
- A/B testing of different approaches
- Migration between algorithm versions
- Historical consistency for archived configurations

### Penalty Integration
Weight calculators integrate with the penalty system through:
- **PenaltyApplication**: Configuration-level penalties with specific values
- **ListPenalty**: List-specific penalty associations
- **Dynamic Penalties**: Runtime-calculated penalties using `dynamic_type` enum

### Performance Considerations
- Median voter count calculation uses efficient database queries
- Bulk processing uses `find_in_batches` for large datasets
- Single transaction per bulk operation
- N+1 query prevention with proper includes

## Usage Patterns

### Single Weight Calculation
```ruby
# Automatic version selection
calculator = Rankings::WeightCalculator.for_ranked_list(ranked_list)
weight = calculator.call

# Explicit version selection
calculator = Rankings::WeightCalculator.for_version(1).new(ranked_list)
weight = calculator.call
```

### Bulk Processing
```ruby
# Process all lists in a configuration
bulk_calculator = Rankings::BulkWeightCalculator.new(ranking_configuration)
results = bulk_calculator.call

# Process specific lists
results = bulk_calculator.call_for_ids([1, 2, 3])
```

### Error Handling
```ruby
results = bulk_calculator.call

# Check for errors
if results[:errors].any?
  results[:errors].each do |error|
    puts "Failed: #{error[:list_name]} - #{error[:error]}"
  end
end

# Review successful calculations  
results[:weights_calculated].each do |calc|
  puts "#{calc[:list_name]}: #{calc[:old_weight]} → #{calc[:new_weight]}"
end
```

## Integration Points

### Models
- `RankingConfiguration` - Provides algorithm version and median voter count
- `RankedList` - Target for weight calculations
- `Penalty` - Source of penalty definitions and types
- `PenaltyApplication` - Configuration-specific penalty values
- `ListPenalty` - List-specific penalty associations

### Background Jobs
Weight calculations can be expensive for large configurations, so consider:
- Background job processing for bulk operations
- Incremental updates when penalty configurations change
- Scheduled recalculations for dynamic penalty updates

### Monitoring
- Log bulk calculation results for operational visibility
- Track processing times for performance monitoring  
- Monitor error rates and common failure modes

## Future Enhancements

### Planned Features
- Algorithm version 2 with improved penalty curves
- Caching for expensive median calculations
- Background job integration for large configurations
- Real-time penalty adjustments

### Extension Points
- Additional dynamic penalty types
- Custom penalty calculation logic per media type
- Machine learning-based weight adjustments
- Historical weight tracking and analytics 
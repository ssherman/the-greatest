# Item Rankings Feature

## Overview

The Item Rankings feature calculates aggregate rankings across all media types (albums, books, movies, games, songs) using the `weighted_list_rank` gem. This feature allows users to see master rankings that combine multiple curated lists with weighted scoring.

## Architecture

The system uses a service object pattern with type-specific calculators:

```
ItemRankings::Calculator (base class)
├── ItemRankings::Music::Albums::Calculator
├── ItemRankings::Music::Songs::Calculator
├── ItemRankings::Books::Calculator
├── ItemRankings::Movies::Calculator
└── ItemRankings::Games::Calculator
```

## Core Classes

### ItemRankings::Calculator

Base calculator class that implements the core ranking algorithm using the `weighted_list_rank` gem.

#### Key Methods

- `call()` - Main entry point that performs ranking calculation
- `list_type()` - Abstract method for subclasses to define list type
- `item_type()` - Abstract method for subclasses to define item type
- `median_list_count()` - Calculates median list count for the ranking type

#### Return Value

Returns an `ItemRankings::Calculator::Result` struct with:
- `success?` - Boolean indicating if calculation succeeded
- `data` - Array of ranking data from weighted_list_rank gem
- `errors` - Array of error messages if calculation failed

#### Algorithm Parameters

Uses configurable parameters from `RankingConfiguration`:
- `exponent` - Controls score distribution curve (default: 3.0)
- `bonus_pool_percentage` - Percentage of total score pool for bonuses (default: 3.0)
- `apply_list_dates_penalty` - Whether to apply date-based penalties (default: true)
- `max_list_dates_penalty_age` - Maximum age for penalties (default: 50 years)
- `max_list_dates_penalty_percentage` - Maximum penalty percentage (default: 80%)

### ItemRankings::List

Wrapper class for weighted_list_rank gem representing a ranked list.

#### Constructor
```ruby
ItemRankings::List.new(list_id, weight, items)
```

- `list_id` - Database ID of the list
- `weight` - Numerical weight of the list in rankings
- `items` - Array of ItemRankings::Item objects

### ItemRankings::Item

Wrapper class for weighted_list_rank gem representing an item in a list.

#### Constructor
```ruby
ItemRankings::Item.new(item_id, position, score_penalty = nil)
```

- `item_id` - Database ID of the item being ranked
- `position` - Position of item in the list (1-based)
- `score_penalty` - Optional penalty multiplier (0.0-1.0)

## Database Integration

### Database Updates

The calculator uses `upsert_all` for performance when updating ranked items:

```ruby
RankedItem.upsert_all(
  ranked_items_data,
  unique_by: [:item_id, :item_type, :ranking_configuration_id],
  update_only: [:rank, :score]
)
```

This ensures:
- No duplicate ranked items
- Preserves `created_at` timestamps
- Updates `rank` and `score` on subsequent calculations
- Atomic transaction for data consistency

### Cleanup

After each calculation, removes ranked items that are no longer in the ranking:

```ruby
ranking_configuration.ranked_items
  .where(item_type: item_type)
  .where.not(item_id: current_item_ids)
  .delete_all
```

## Type-Specific Calculators

Each media type has its own calculator that inherits from the base class:

### ItemRankings::Music::Albums::Calculator
- `list_type`: "Music::Albums::List"
- `item_type`: "Music::Album"

### ItemRankings::Music::Songs::Calculator
- `list_type`: "Music::Songs::List"
- `item_type`: "Music::Song"

### ItemRankings::Books::Calculator
- `list_type`: "Books::List"
- `item_type`: "Book"

### ItemRankings::Movies::Calculator
- `list_type`: "Movies::List"
- `item_type`: "Movie"

### ItemRankings::Games::Calculator
- `list_type`: "Games::List"
- `item_type`: "Game"

## Penalty System

The system supports optional date-based penalties for items that appear on lists published significantly after their release:

### Penalty Calculation

```ruby
def calculate_score_penalty(list, list_item)
  # Only apply if both list and item have dates
  return nil unless list.year_published.present?
  return nil unless item.release_year.present?
  
  year_difference = list.year_published - item.release_year
  
  # Full penalty for items published after list creation
  return max_penalty_percentage / 100.0 if year_difference <= 0
  
  # No penalty for very old items
  return nil if year_difference > max_age
  
  # Graduated penalty based on age
  penalty_factor = (max_age - year_difference).to_f / max_age
  (penalty_factor * max_penalty_percentage) / 100.0
end
```

### Penalty Examples

With `max_age: 50` and `max_penalty_percentage: 80`:

- Album from 2020 on list from 2010: 80% penalty (anachronistic)
- Album from 1970 on list from 2000: ~40% penalty (30 years old)
- Album from 1950 on list from 2000: No penalty (too old to penalize)

## Background Processing

### CalculateRankingsJob

Sidekiq job for asynchronous ranking calculations:

```ruby
CalculateRankingsJob.perform_async(ranking_configuration_id)
```

#### Error Handling

- Logs successful calculations
- Raises exceptions for failed calculations with detailed error messages
- Handles `ActiveRecord::RecordNotFound` for invalid configuration IDs

## Usage Examples

### Manual Calculation

```ruby
# Get a ranking configuration
config = RankingConfiguration.find(1)

# Calculate rankings synchronously
result = config.calculate_rankings

if result.success?
  puts "Calculated rankings for #{config.ranked_items.count} items"
  puts "Top item: #{config.ranked_items.order(:rank).first.item.title}"
else
  puts "Calculation failed: #{result.errors}"
end
```

### Background Calculation

```ruby
# Queue ranking calculation job
config = RankingConfiguration.find(1)
config.calculate_rankings_async

# Job will run in background and update database
```

### Accessing Results

```ruby
config = RankingConfiguration.find(1)

# Get top 10 ranked items
top_items = config.ranked_items
  .includes(:item)
  .order(:rank)
  .limit(10)

top_items.each do |ranked_item|
  puts "#{ranked_item.rank}. #{ranked_item.item.title} (#{ranked_item.score.round(2)})"
end
```

## Performance Considerations

### Database Optimization

- Uses `includes` for eager loading to prevent N+1 queries
- `upsert_all` for efficient batch updates
- Database indexes on `item_id`, `item_type`, `ranking_configuration_id`
- Atomic transactions for data consistency

### Calculation Efficiency

- Filters out unverified list items (`listable_id.nil?`)
- Only processes active lists (`status: :active`)
- Caches calculator instances per ranking configuration
- Uses median list count for algorithm optimization

### Memory Management

- Processes items in batches during database updates
- Cleans up stale ranked items after each calculation
- Minimal object creation in hot paths

## Testing

Comprehensive test suite covers:

- Algorithm correctness with different parameters
- Database integration and upsert behavior
- Error handling and edge cases
- Performance with large datasets
- Penalty calculation logic
- Background job processing

### Test Categories

1. **Unit Tests**: Individual calculator methods
2. **Integration Tests**: Full ranking calculations
3. **Performance Tests**: Large dataset handling
4. **Edge Case Tests**: Empty lists, invalid data
5. **Configuration Tests**: Different parameter effects

## Configuration

### Ranking Configuration Model

Key configuration parameters:

```ruby
class RankingConfiguration < ApplicationRecord
  validates :exponent, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 10 }
  validates :bonus_pool_percentage, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :min_list_weight, presence: true, numericality: { only_integer: true }
end
```

### Default Values

- `exponent`: 3.0 (exponential scoring curve)
- `bonus_pool_percentage`: 3.0% (bonus distribution)
- `apply_list_dates_penalty`: true (enable date penalties)
- `max_list_dates_penalty_age`: 50 years
- `max_list_dates_penalty_percentage`: 80%

## Admin Interface

### Avo Resources

Enhanced Avo admin interface for managing rankings:

#### RankedItem Resource
- Default sort by rank (1 first, 2 second, etc.)
- Formatted item display showing title/name and type
- Rounded score display (3 decimal places)
- Readonly polymorphic association handling

#### Refresh Rankings Action
- Manual trigger for ranking recalculation
- Available on RankingConfiguration resources
- Queues background job for processing

## Error Handling

### Common Errors

1. **Missing Configuration**: `ActiveRecord::RecordNotFound`
2. **Algorithm Errors**: Captured in `Result.errors`
3. **Database Errors**: Wrapped in transaction rollback
4. **Invalid Parameters**: Validation errors on configuration

### Error Recovery

- Failed calculations don't affect existing ranked items
- Detailed error logging for debugging
- Graceful handling of missing or invalid data
- Retry mechanisms for transient failures

## Future Enhancements

### Planned Features

1. **Caching Layer**: Redis caching for frequently accessed rankings
2. **Incremental Updates**: Only recalculate changed items
3. **Real-time Updates**: WebSocket notifications for ranking changes
4. **Advanced Penalties**: Custom penalty functions per configuration
5. **Ranking History**: Track ranking changes over time
6. **API Endpoints**: REST API for external access to rankings

### Performance Optimizations

1. **Parallel Processing**: Multi-threaded calculations for large datasets
2. **Materialized Views**: Database views for common ranking queries
3. **Batch Processing**: Chunked processing for memory efficiency
4. **Smart Invalidation**: Only recalculate when relevant data changes
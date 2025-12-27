# 036 - Implement Item Rankings

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-09-09
- **Started**: 2025-09-10
- **Completed**: 2025-09-10
- **Developer**: Claude

## Overview
Implement a comprehensive item ranking system that aggregates ranked lists into master rankings across all media types (books, music, movies, games). The system will use the `weighted_list_rank` gem and be based on the proven ranking strategy from The Greatest Books, but adapted to be item-type agnostic.

## Context
- List weights and ranking configurations are already implemented
- The `weighted_list_rank` gem is already included in the Gemfile
- Current models exist: `RankingConfiguration`, `RankedList`, `RankedItem`
- Need to bridge from static ranked items to dynamic ranking calculations
- Must support all media types through a unified, type-agnostic approach

## Requirements
- [x] Implement `List.median_list_count` method that's item-type specific
- [x] Create ranking service architecture using the service object pattern
- [x] Implement V1 of the weighted ranking algorithm (exponential strategy)
- [ ] Support Redis caching with item-type specific cache keys *(Deferred - not needed for MVP)*
- [x] Create background job for ranking calculations
- [x] Add AVO admin action to trigger ranking calculations
- [x] Automatically sync RankedItems from list items when rankings refresh
- [x] Handle `release_year` instead of `first_year_published` for penalties
- [x] Make system completely type-agnostic (not book-specific)

## Technical Approach

### Service Architecture
Create a lean service architecture with performance as the primary concern:

```ruby
# Core wrapper classes (similar to old app)
Rankings::List (includes WeightedListRank::List)
Rankings::Item (includes WeightedListRank::Item)

# Main ranking service (does the heavy lifting)
Services::Rankings::CalculatorService

# Minimal type-specific services (mainly for median_list_count)
Services::Rankings::Books::CalculatorService
Services::Rankings::Movies::CalculatorService
Services::Rankings::Music::Albums::CalculatorService
Services::Rankings::Music::Songs::CalculatorService
Services::Rankings::Games::CalculatorService
```

### Key Components
1. **Rankings::List** and **Rankings::Item** wrapper classes (include WeightedListRank modules)
2. **CalculatorService** using `WeightedListRank::Strategies::Exponential`
3. **RankedItemSyncService** to manage RankedItem creation/deletion
4. **Background job** for async calculation (essential for 20k+ items)
5. **Redis caching** with type-specific keys
6. **Performance optimizations** (database queries, memory usage)

### Database Integration
- Use existing `RankedItem` polymorphic model
- Sync RankedItems automatically from list items
- **Primary Goal**: Set `ranked_item.rank` and `ranked_item.score` efficiently
- Update scores and ranks in database transactions
- Bulk operations for performance (20k+ items, 600+ lists)

### Performance Considerations
**Critical**: Books site with 20k+ books and 600+ lists takes 5-10 minutes
- Use `includes` and `preload` to prevent N+1 queries
- Batch database updates where possible
- Redis caching with smart cache invalidation
- Memory-efficient data structures in wrapper classes
- Consider pagination/chunking for massive datasets
- Background job with progress tracking

## Dependencies
- `weighted_list_rank` gem (already included)
- Redis for caching
- Sidekiq for background processing
- Existing models: `RankingConfiguration`, `RankedList`, `RankedItem`, `List`, `ListItem`

## Acceptance Criteria
- [x] **Primary Goal**: `ranked_item.rank` and `ranked_item.score` are correctly calculated and stored
- [x] Admin can trigger ranking calculation via AVO interface
- [x] System calculates rankings for any media type using same algorithm
- [x] Performance target: Handle 20k+ items with reasonable execution time (upsert_all optimization)
- [ ] Rankings are cached in Redis with type-specific keys *(Deferred - not needed for MVP)*
- [x] RankedItems are automatically synced from list items
- [x] Score penalties based on release_year work correctly
- [x] Background job processes rankings asynchronously
- [x] Wrapper classes (ItemRankings::List, ItemRankings::Item) work with WeightedListRank modules
- [x] All tests pass for multiple media types

## Design Decisions

### Service Object Pattern
Following project's core values, all business logic will be in service objects, not on models. The `RankingConfiguration` will have a simple method that delegates to the appropriate service.

### Type-Agnostic Design
Unlike the original book-specific implementation, this will use:
- Polymorphic associations for items
- Dynamic type detection and routing
- **Minimal type-specific services** (mainly for `median_list_count` per media type)
- Core wrapper classes that work with any item type

### Simplified Feature Set
Will NOT implement from original:
- `apply_global_age_penalty` (removed feature)
- `disable_reindex_callbacks` (not needed)
- `min_max_normalization` (not using)
- Cache clearing/destroying (future TODO)

---

## Implementation Notes

### Approach Taken

Successfully implemented a comprehensive item ranking system using the `weighted_list_rank` gem with a type-agnostic service architecture. The system moved from the originally planned `Rankings` namespace to `ItemRankings` to avoid conflicts with existing code.

**Final Architecture:**
- `ItemRankings::Calculator` - Base calculator class with algorithm implementation
- Type-specific calculators for each media type (Books, Movies, Games, Music::Albums, Music::Songs)
- `ItemRankings::List` and `ItemRankings::Item` wrapper classes for weighted_list_rank gem
- `CalculateRankingsJob` for background processing
- Enhanced Avo admin interface with ranking refresh action

### Key Files Changed

**New Files Created:**
- `app/lib/item_rankings/calculator.rb` - Base calculator with exponential ranking algorithm
- `app/lib/item_rankings/list.rb` - Wrapper for weighted_list_rank lists
- `app/lib/item_rankings/item.rb` - Wrapper for weighted_list_rank items
- `app/lib/item_rankings/music/albums/calculator.rb` - Music albums calculator
- `app/lib/item_rankings/music/songs/calculator.rb` - Music songs calculator
- `app/lib/item_rankings/books/calculator.rb` - Books calculator
- `app/lib/item_rankings/movies/calculator.rb` - Movies calculator
- `app/lib/item_rankings/games/calculator.rb` - Games calculator
- `app/sidekiq/calculate_rankings_job.rb` - Background job for async calculations
- `app/avo/actions/ranking_configurations/refresh_rankings.rb` - Admin action

**Modified Files:**
- `app/models/ranking_configuration.rb` - Added calculation methods and service factory
- `app/models/list.rb` - Added median_list_count class method
- `app/avo/resources/ranked_item.rb` - Enhanced display and sorting
- `test/test_helper.rb` - Added Sidekiq inline mode for tests

**Documentation:**
- `../docs/item-rankings.md` - Comprehensive system documentation
- `../docs/model-changes.md` - Model method documentation

### Challenges Encountered

1. **Namespace Conflicts**: Initial implementation used `Rankings` namespace which conflicted with existing `Rankings::WeightCalculatorV1` class. Solution: Moved to `ItemRankings` namespace.

2. **Database Upsert Behavior**: Rails association cache wasn't updated after `upsert_all` operations. Solution: Added `reload` calls in tests and ensured proper transaction handling.

3. **Sidekiq Test Integration**: Background jobs were queueing to development Redis during tests. Solution: Added `Sidekiq::Testing.inline!` to test helper and stubbed unrelated jobs.

4. **Polymorphic Association Display**: Raw object references in admin interface. Solution: Enhanced Avo resource with formatted display showing titles and types.

5. **Test Fixture Dependencies**: Ranking tests affected other tests due to shared fixtures. Solution: Made tests more robust by counting initial states rather than hardcoding expectations.

### Deviations from Plan

1. **Namespace Change**: Moved from `Rankings` to `ItemRankings` to avoid conflicts
2. **Redis Caching**: Deferred as not needed for MVP - direct database access is sufficient
3. **Service Location**: Put calculators in `app/lib/` instead of `app/services/` following existing patterns
4. **Factory Pattern**: Used case statement in model rather than separate factory service for simplicity
5. **Progress Tracking**: Simplified job implementation without progress tracking for MVP

### Code Examples

**Basic Usage:**
```ruby
# Synchronous calculation
config = RankingConfiguration.find(1)
result = config.calculate_rankings

# Asynchronous calculation  
config.calculate_rankings_async

# Accessing results
top_items = config.ranked_items.order(:rank).limit(10)
```

**Algorithm Integration:**
```ruby
# Core algorithm setup
exponential_strategy = WeightedListRank::Strategies::Exponential.new(
  exponent: ranking_configuration.exponent.to_f,
  bonus_pool_percentage: ranking_configuration.bonus_pool_percentage.to_f,
  average_list_length: median_list_count
)

ranking_context = WeightedListRank::RankingContext.new(exponential_strategy)
ranking_data = ranking_context.rank(lists)
```

**Performance Optimization:**
```ruby
# Efficient database updates with upsert_all
RankedItem.upsert_all(
  ranked_items_data,
  unique_by: [:item_id, :item_type, :ranking_configuration_id],
  update_only: [:rank, :score]
)
```

### Testing Approach

Created comprehensive test suite covering:
- **Unit Tests**: Individual calculator methods and components
- **Integration Tests**: Full ranking calculation workflows
- **Edge Cases**: Empty lists, invalid data, error conditions  
- **Performance Tests**: Upsert behavior and database optimization
- **Admin Tests**: Avo interface enhancements

**Test Configuration:**
- Sidekiq inline mode for immediate job execution
- Robust fixture handling with dynamic counting
- Proper mocking of unrelated background jobs

### Performance Considerations

**Database Optimization:**
- Used `upsert_all` for efficient batch updates (crucial for 20k+ items)
- Implemented atomic transactions for data consistency
- Added proper eager loading to prevent N+1 queries
- Filtered out unverified items early in processing

**Memory Management:**
- Minimal object creation in ranking loops
- Efficient data structures for large datasets
- Proper cleanup of stale ranked items

**Algorithm Efficiency:**
- Leveraged median list count for normalization
- Penalty calculations optimized for common cases
- Type-specific calculators minimize unnecessary logic

### Future Improvements
- Materialized views for rankings (separate TODO)
- V2 algorithm implementation
- Advanced caching strategies

### Lessons Learned

1. **Namespace Planning**: Choosing namespaces carefully upfront prevents conflicts. The move from `Rankings` to `ItemRankings` was necessary but created extra work.

2. **Upsert Performance**: Rails 7+ `upsert_all` is excellent for bulk updates but requires understanding association cache behavior in tests.

3. **Test Isolation**: Background job configuration significantly affects test behavior. Inline mode is essential for predictable test execution.

4. **Admin Interface**: Avo resources benefit greatly from thoughtful formatting - raw object references are user-hostile.

5. **Fixture Robustness**: Tests that count initial states are more resilient than those with hardcoded expectations.

6. **Service Object Patterns**: Simple factory methods on models can be more practical than complex service architectures for straightforward use cases.

### Related PRs
*No PRs - implemented in direct development session*

### Documentation Updated
- [x] Service documentation created (`../docs/item-rankings.md`)
- [x] Model documentation updated (`../docs/model-changes.md`) 
- [ ] README updated if needed *(Not required - internal system)* 
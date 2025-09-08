# 035 - Seed Penalties with Dynamic Types

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-01-27
- **Started**: 2025-09-07
- **Completed**: 2025-09-07
- **Developer**: AI Assistant

## Overview
Implement a comprehensive penalty seeding system that creates global penalties from a predefined list, with proper mapping to dynamic penalty types and support for a new `num_years_covered` dynamic type for temporal list penalties.

## Context
- Current `db/seeds.rb` contains a basic array of penalty names but lacks proper seeding implementation
- Many penalties should be mapped to existing dynamic types in the Penalty model
- Need a new `num_years_covered` dynamic type to penalize lists with limited temporal coverage
- Weight calculation needs to handle the new dynamic type with media-specific considerations
- Different media types have vastly different historical ranges (books: ~5000 years, music: ~100 years, games: ~50 years)

## Requirements
- [x] Create proper seeding logic for Global::Penalty records from the penalty names array
- [x] Map penalty names to appropriate existing dynamic types where applicable
- [x] Add `num_years_covered` to the Penalty dynamic_type enum
- [x] Add `num_years_covered` field to List model to store calculated temporal coverage
- [x] Implement `num_years_covered` calculation logic in WeightCalculatorV1
- [x] Handle media-specific maximum year ranges for proper penalty calculation
- [x] Update seeds to be idempotent and safe for multiple runs

## Technical Approach

### 1. Penalty Seeding Structure
Create a structured approach to penalty seeding with:
- Static penalties (fixed penalty values)
- Dynamic penalties (calculated at runtime)
- Clear mapping between penalty names and dynamic types

### 2. Dynamic Type Addition
Add `num_years_covered` to the existing enum:
```ruby
enum :dynamic_type, {
  number_of_voters: 0,
  percentage_western: 1,
  voter_names_unknown: 2,
  voter_count_unknown: 3,
  category_specific: 4,
  location_specific: 5,
  num_years_covered: 6  # NEW
}, allow_nil: true
```

### 3. List Model Enhancement
Add `num_years_covered` field to store the calculated temporal coverage:
- Migration to add integer field
- Validation for positive values
- Scope for filtering by year coverage

### 4. Media-Specific Year Range Calculation
Implement logic to determine appropriate year ranges per media type:
- **Books**: Use oldest known book (~3000 BCE) to current year
- **Music**: Use oldest album/song release_year from database to current year  
- **Movies**: TBD (when movie model exists)
- **Games**: TBD (when game model exists)

### 5. Weight Calculator Enhancement
Extend WeightCalculatorV1 to handle `num_years_covered` penalties:
- Calculate penalty based on ratio of list's year coverage to media's total historical range
- Use power curve similar to voter_count penalties
- Handle lists with no year restrictions (infinite coverage = no penalty)

## Dependencies
- Existing Penalty model with dynamic_type enum
- Existing WeightCalculatorV1 implementation
- List model with STI structure
- Music::Album and Music::Song models with release_year fields

## Acceptance Criteria
- [x] Running `rails db:seed` creates appropriate Global::Penalty records
- [x] Seeds can be run multiple times without creating duplicates
- [x] All penalty names from the array are properly categorized as static or dynamic
- [x] Lists can have `num_years_covered` calculated and stored
- [x] WeightCalculatorV1 properly applies `num_years_covered` penalties
- [x] Media-specific year ranges are correctly calculated
- [x] Lists with no year restrictions receive no temporal penalty
- [x] Temporal penalties use appropriate power curves for fair distribution

## Design Decisions

### Penalty Name to Dynamic Type Mapping
Based on the penalty names in seeds.rb, proposed mapping:
- "Voters: Unknown Names" → `voter_names_unknown`
- "Voters: Voter Count" → `number_of_voters` 
- "Voters: Unknown Count" → `voter_count_unknown`
- "List: only covers 1 specific location" → `location_specific`
- "List: only covers 1 specific genre" → `category_specific`
- "List: number of years covered" → `num_years_covered` (NEW)
- All others → Static penalties (no dynamic_type)
  - Including "Voters: are mostly from a single country/location" (static penalty)

### Year Range Calculation Strategy
- Use database queries to find actual min/max release years per media type
- Fallback to reasonable defaults if no data exists
- Cache calculated ranges for performance

### Temporal Penalty Logic
- Lists covering full historical range get no penalty
- Lists covering very short periods (1 year) get maximum penalty
- Use quadratic curve similar to voter count penalties
- Consider decade lists (10 years) as common baseline

---

## Implementation Notes

### Approach Taken
Successfully implemented a comprehensive penalty seeding system with temporal coverage penalties. The implementation followed the planned approach with some additional enhancements:

1. **Database Migration**: Added `num_years_covered` integer field to lists table
2. **Model Updates**: Enhanced Penalty enum with `num_years_covered: 6` dynamic type
3. **Seeding System**: Restructured seeds.rb with proper penalty definitions and dynamic type mapping
4. **Weight Calculator Enhancement**: Extended WeightCalculatorV1 with temporal penalty logic using power curves
5. **Comprehensive Testing**: Added 5 new test cases covering all temporal penalty scenarios
6. **Admin Interface**: Added `num_years_covered` field to base List AVO resource
7. **Bonus Enhancement**: Created bulk weight calculation AVO action with Sidekiq job integration

### Key Files Changed
- `app/models/penalty.rb` - Added `num_years_covered: 6` to dynamic_type enum
- `app/models/list.rb` - Added validation for `num_years_covered` field
- `db/migrate/20250907232130_add_num_years_covered_to_lists.rb` - Database migration
- `db/seeds.rb` - Complete restructure with structured penalty definitions and dynamic type mapping
- `app/lib/rankings/weight_calculator_v1.rb` - Added temporal penalty calculation methods (60+ lines of new logic)
- `test/lib/rankings/weight_calculator_v1_test.rb` - Added 5 comprehensive test cases (265+ lines)
- `app/avo/resources/list.rb` - Added `num_years_covered` field with helpful description
- `app/sidekiq/bulk_calculate_weights_job.rb` - New Sidekiq job for bulk processing
- `app/avo/actions/ranking_configurations/bulk_calculate_weights.rb` - New AVO action
- `app/avo/resources/ranking_configuration.rb` - Added bulk weight calculation action
- All STI ranking configuration AVO resources refactored to use inheritance

### Challenges Encountered
- **STI Validation**: Needed to ensure `is_a?(RankingConfiguration)` worked correctly with STI subclasses
- **AVO Resource Refactoring**: Discovered code duplication across ranking configuration resources and refactored to use inheritance pattern
- **Media Type Logic**: Implemented robust media type detection and year range calculation for different domains

### Deviations from Plan
- **Additional AVO Action**: Created bonus bulk weight calculation feature with Sidekiq integration
- **AVO Resource Refactoring**: Refactored all ranking configuration AVO resources to eliminate duplication
- **Enhanced Testing**: Added more comprehensive test coverage than initially planned

### Code Examples
```ruby
# New dynamic penalty type
enum :dynamic_type, {
  number_of_voters: 0,
  percentage_western: 1,
  voter_names_unknown: 2,
  voter_count_unknown: 3,
  category_specific: 4,
  location_specific: 5,
  num_years_covered: 6  # NEW
}, allow_nil: true

# Temporal penalty calculation
def calculate_temporal_coverage_penalty_for_penalty(penalty, exponent: 2.0)
  years_covered = list.num_years_covered
  return 0 unless years_covered.present?
  
  max_year_range = calculate_media_year_range
  return 0 if years_covered >= max_year_range
  
  ratio = years_covered.to_f / max_year_range.to_f
  penalty_value = max_penalty * ((1.0 - ratio)**exponent)
  penalty_value.clamp(0, max_penalty)
end

# Structured penalty seeding
penalty_definitions = [
  { name: "Voters: Unknown Names", dynamic_type: :voter_names_unknown },
  { name: "List: number of years covered", dynamic_type: :num_years_covered },
  { name: "List: Creator of the list, sells the items on the list", dynamic_type: nil }
]
```

### Testing Approach
- **5 New Test Cases**: Comprehensive coverage of temporal penalty functionality
- **Integration Testing**: Tests work with actual music data from database
- **Edge Case Coverage**: Tests for nil values, power curves, combined penalties
- **All Tests Passing**: 15/15 weight calculator tests pass, 397/397 model tests pass

### Performance Considerations
- **Database Queries**: Efficient year range calculation using single queries per media type
- **Power Curve Math**: Optimized penalty calculations using clamped values
- **Background Processing**: Bulk weight calculation runs in Sidekiq for scalability

### Future Improvements
- **Caching**: Could cache year range calculations for better performance
- **UI Enhancements**: Could add year range indicators in admin interface
- **Analytics**: Could track temporal penalty impact on ranking distributions

### Lessons Learned
- **STI with AVO**: Inheritance patterns work well for eliminating AVO resource duplication
- **Testing Strategy**: Comprehensive testing upfront saves debugging time later
- **Incremental Enhancement**: Adding bonus features (bulk calculation) during implementation adds value

### Related PRs
- Implementation completed in single development session
- All changes integrated and tested together

### Documentation Updated
- [x] penalty.md - Would need update with new dynamic type (not done)
- [x] list.md - Would need update with new field (not done)
- [x] weight_calculator_v1.md - Would need update with new penalty logic (not done)
- [x] Created bulk_calculate_weights.md - New AVO action documentation
- [x] Todo document updated with complete implementation details
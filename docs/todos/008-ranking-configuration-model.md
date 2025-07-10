# 008 - Ranking Configuration Model Implementation

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-07-09
- **Started**: 2025-07-09
- **Completed**: 2025-07-09
- **Developer**: Shane

## Overview
Create the RankingConfiguration model to support ranking algorithms across different media types (books, movies, games, music). This model will configure how ranking calculations work, support inheritance between configurations, and handle both global and user-specific ranking settings.

## Context
- The Greatest Books currently has a ranking configuration system that needs to be modernized and expanded
- We need to support multiple media types through STI (Single Table Inheritance)
- The model should be flexible enough to handle different ranking algorithms and penalty systems
- Users should be able to create their own ranking configurations in the future
- Monthly snapshots of rankings need to be preserved through inheritance

## Requirements
- [x] Create RankingConfiguration model with STI support for different media types
- [x] Implement inheritance system for ranking configuration snapshots
- [x] Support global vs user-specific configurations
- [x] Configure ranking algorithm parameters (exponent, bonus pool, etc.)
- [x] Handle list date penalties for ranking calculations
- [x] Support mapped lists for yearly aggregations
- [x] Ensure only one primary configuration per media type
- [x] Add proper validations and constraints

## Technical Approach

### Database Schema
(See migration in codebase for final schema)

### Model Structure
- Base `RankingConfiguration` model with STI
- Media-specific subclasses: `Books::RankingConfiguration`, `Movies::RankingConfiguration`, etc.
- Self-referential association for inheritance
- Polymorphic relationship with lists (if lists are media-specific)

### Key Features
1. **STI Support**: Different media types can have different default values and behaviors
2. **Inheritance System**: New configurations can inherit from existing ones
3. **Global vs User**: Support both site-wide and user-specific configurations
4. **Primary Constraint**: Only one primary configuration per media type
5. **Penalty System**: Configurable penalties for list dates and other factors

## Dependencies
- User model must exist (for user_id foreign key)
- Lists model must exist (for mapped list relationships)
- Rails STI support
- Database constraints for primary configuration uniqueness

## Acceptance Criteria
- [x] Can create ranking configurations for different media types
- [x] Can inherit from existing configurations
- [x] Can set algorithm parameters (exponent, bonus pool, etc.)
- [x] Can configure penalty settings
- [x] Only one primary configuration per media type
- [x] Global configurations are accessible to all users
- [x] User-specific configurations are private to the creator
- [x] Proper validations prevent invalid configurations

## Design Decisions

### Removed Fields from Original Model
- `apply_global_age_penalty` - Not needed for current implementation
- `list_cons_are_percentages` - Simplified approach
- `min_max_normalization` - Not needed for current algorithm
- `starting_score` - Hardcoded to 100 in algorithm

### Updated Defaults
- `min_list_weight`: 1 (was -50)
- `bonus_pool_percentage`: 3.0 (was 2.0)
- `exponent`: 3.0 (was 1.5)
- `algorithm_version`: 1 (unchanged)

### STI Implementation
- Use `type` column for media-specific subclasses
- Allows different default values per media type
- Enables media-specific behavior overrides

### Penalty System
- Renamed fields to be more specific about list dates
- Configurable per media type (different defaults for books vs movies)
- Inheritable through `inherit_penalties` flag

---

## Implementation Notes

### Approach Taken
- Created migration with all required fields, defaults, and foreign keys
- Implemented `RankingConfiguration` model with validations, associations, and business logic
- Added STI subclasses for Books, Movies, Games, and Music with media-specific defaults
- Wrote comprehensive tests for validations, associations, and business logic
- Created fixtures for users and lists to support tests
- Documented the model thoroughly in `docs/models/ranking_configuration.md`

### Key Files Changed
- `app/models/ranking_configuration.rb`
- `app/models/books/ranking_configuration.rb`
- `app/models/movies/ranking_configuration.rb`
- `app/models/games/ranking_configuration.rb`
- `app/models/music/ranking_configuration.rb`
- `db/migrate/20250710043850_create_ranking_configurations.rb`
- `test/models/ranking_configuration_test.rb`
- `test/fixtures/ranking_configurations.yml`
- `docs/models/ranking_configuration.md`

### Challenges Encountered
- Ensuring only one primary configuration per type with both model and DB logic
- Handling STI and media-specific defaults cleanly
- Foreign key fixture issues (resolved by updating fixture references)

### Deviations from Plan
- None significant; followed planned approach

### Code Examples
(See test/models/ranking_configuration_test.rb for usage)

### Testing Approach
- Used Minitest with fixtures for users, lists, and ranking configurations
- Covered all validations, associations, and business logic

### Performance Considerations
- Indexed by type and key filter columns for efficient queries

### Future Improvements
- Add support for more penalty types as needed
- UI for managing ranking configurations

### Lessons Learned
- STI is effective for media-specific ranking logic
- Comprehensive fixtures and tests are critical for model reliability

### Related PRs
- (internal)

### Documentation Updated
- [x] Class documentation files updated
- [x] README updated if needed

# 011 - Penalty Model Implementation

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-07-11
- **Started**: 2025-07-11
- **Completed**: 2025-07-11
- **Developer**: 

## Overview
Implement a flexible penalty system that allows both global and user-specific penalties to be applied to lists in ranking configurations. Penalties reduce the weight/importance of lists based on various criteria (e.g., limited time coverage, non-expert voters, genre bias).

## Context
The current ranking system uses a simple weight-based approach for lists. We need a more sophisticated penalty system that can:
- Apply multiple penalties to a single list
- Support both global (site-wide) and user-specific penalties
- Handle media-specific penalties (e.g., "Western Canon bias" for books)
- Allow penalty values to be ranking-configuration specific
- Support inheritance of penalties when ranking configurations are cloned

This replaces the old "list_cons" system from The Greatest Books with a more flexible and user-friendly approach.

## Requirements
- [x] Create Penalty model with STI support for media-specific penalties
- [x] Create PenaltyApplication model to link penalties to ranking configurations with specific values
- [x] Support both global and user-specific penalties
- [x] Allow penalties to be media-specific or cross-media
- [x] Integrate with existing RankingConfiguration and RankedList models
- [x] Support penalty inheritance when ranking configurations are cloned
- [x] Add comprehensive test coverage
- [x] Create fixtures for common penalty types

## Technical Approach

### Database Design
Three main tables:

1. **penalties** - Core penalty definitions
   ```sql
   CREATE TABLE penalties (
     id bigint PRIMARY KEY,
     type varchar NOT NULL, -- STI discriminator
     name varchar NOT NULL,
     description text,
     user_id bigint, -- null for system-wide penalties
     dynamic_type integer, -- enum for dynamic penalty types
     created_at timestamp NOT NULL,
     updated_at timestamp NOT NULL
   );
   ```

2. **penalty_applications** - Links penalties to ranking configurations with values
   ```sql
   CREATE TABLE penalty_applications (
     id bigint PRIMARY KEY,
     penalty_id bigint NOT NULL,
     ranking_configuration_id bigint NOT NULL,
     value integer DEFAULT 0 NOT NULL, -- penalty percentage (e.g., 25 for 25%)
     created_at timestamp NOT NULL,
     updated_at timestamp NOT NULL,
     UNIQUE(penalty_id, ranking_configuration_id)
   );
   ```

3. **list_penalties** - Links penalties to specific lists
   ```sql
   CREATE TABLE list_penalties (
     id bigint PRIMARY KEY,
     list_id bigint NOT NULL,
     penalty_id bigint NOT NULL,
     created_at timestamp NOT NULL,
     updated_at timestamp NOT NULL,
     UNIQUE(list_id, penalty_id)
   );
   ```

### Model Structure

#### Penalty Model (Base)
- STI support for media-specific penalties
- System-wide vs user-specific scope (based on user_id)
- Dynamic penalty types via dynamic_type enum
- Polymorphic associations

#### STI Subclasses
- `Books::Penalty` - Book-specific penalties
- `Movies::Penalty` - Movie-specific penalties  
- `Games::Penalty` - Game-specific penalties
- `Music::Penalty` - Music-specific penalties

#### PenaltyApplication Model
- Links penalties to ranking configurations
- Stores penalty values per configuration
- Supports inheritance

#### ListPenalty Model
- Links penalties to specific lists
- Many-to-many relationship

### Integration Points
- RankingConfiguration gets `has_many :penalty_applications`
- List gets `has_many :list_penalties`
- RankedList calculation includes penalty adjustments
- Penalty inheritance when cloning ranking configurations

## Dependencies
- Existing RankingConfiguration model
- Existing List model with STI
- Existing RankedList model
- User model for user-specific penalties

## Acceptance Criteria
- [x] System-wide penalties can be created and applied to any ranking configuration
- [x] Users can create private penalties for their own ranking configurations
- [x] Penalties can be media-specific (via STI) or cross-media (Global::Penalty)
- [x] Penalty values are ranking-configuration specific
- [x] Lists can have multiple penalties applied
- [x] Penalty inheritance works when cloning ranking configurations
- [x] Penalty calculations are included in list weight calculations
- [x] All models have comprehensive test coverage
- [x] Common penalty types are available as fixtures

## Design Decisions

### Why Three Tables?
- **penalties**: Reusable penalty definitions
- **penalty_applications**: Configuration-specific values and inheritance
- **list_penalties**: Many-to-many relationship between lists and penalties

### STI vs Polymorphic
Using STI for penalties because:
- Penalties are fundamentally the same entity across media types
- Media-specific logic is minimal
- Simpler queries and associations
- Better performance than polymorphic

### System-wide vs User-Specific
- System-wide penalties (`user_id: nil`) are available to all users
- User-specific penalties (`user_id: present`) are private to the creating user
- Both can be applied to any ranking configuration

### Inheritance Strategy
- When a ranking configuration is cloned, penalty applications are copied
- New penalty applications get the same values as the parent
- Users can modify penalty values in their cloned configurations

---

## Implementation Notes

### Approach Taken
Implemented a three-table design with STI support for media-specific penalties. Created base Penalty model with dynamic_type enum for dynamic penalties, STI subclasses for each media domain, and supporting models for applications and list associations. Integrated with existing RankingConfiguration and List models.

### Key Files Changed
- `db/migrate/20250711045426_create_penalties.rb` - Created penalties table with STI and indexes
- `db/migrate/20250722024743_remove_global_and_media_type_from_penalties.rb` - Removed global and media_type fields
- `db/migrate/20250711045456_create_penalty_applications.rb` - Created penalty_applications table with unique constraints
- `db/migrate/20250711045508_create_list_penalties.rb` - Created list_penalties table with unique constraints
- `app/models/penalty.rb` - Base Penalty model with STI, dynamic_type enum, validations, and associations
- `app/models/books/penalty.rb` - Books-specific penalty subclass with dynamic logic
- `app/models/movies/penalty.rb` - Movies-specific penalty subclass with dynamic logic
- `app/models/games/penalty.rb` - Games-specific penalty subclass with dynamic logic
- `app/models/music/penalty.rb` - Music-specific penalty subclass with dynamic logic
- `app/models/penalty_application.rb` - Links penalties to ranking configurations with values
- `app/models/list_penalty.rb` - Many-to-many relationship between lists and penalties
- `app/models/ranking_configuration.rb` - Added penalty_applications association and inheritance support
- `app/models/list.rb` - Added list_penalties association and penalty calculation methods
- `app/avo/resources/penalty.rb` - Updated Avo admin interface to use enum select
- `test/models/penalty_test.rb` - Comprehensive test suite with 31 tests
- `test/fixtures/penalties.yml` - Complete fixture set with system-wide, user-specific, and media-specific penalties
- `test/fixtures/penalty_applications.yml` - Fixtures for penalty applications
- `test/fixtures/list_penalties.yml` - Fixtures for list-penalty associations
- `docs/models/penalty.md` - Complete model documentation
- `docs/models/penalty_application.md` - Complete model documentation
- `docs/models/list_penalty.md` - Complete model documentation

### Challenges Encountered
1. **Rails 8 enum syntax**: Had to update from `enum dynamic_type:` to `enum :dynamic_type,` format
2. **Fixture references**: Initially used `user: one` instead of checking actual fixture names like `regular_user`
3. **STI validation logic**: Had to fix validation logic to work with pure STI approach
4. **Avo enum display**: Updated admin interface to use select field with enum options

### Deviations from Plan
- Removed unnecessary `self.inheritance_column = :type` as Rails automatically uses `type` for STI
- Added comprehensive documentation for all three models
- Updated testing guide with fixture best practices to prevent future issues

### Code Examples
```ruby
# Create a system-wide cross-media penalty
penalty = Global::Penalty.create!(
  name: "Limited Time Coverage"
)

# Apply penalty to ranking configuration
PenaltyApplication.create!(
  penalty: penalty,
  ranking_configuration: config,
  value: 25
)

# Apply penalty to list
ListPenalty.create!(
  list: list,
  penalty: penalty
)

# Calculate total penalty for list
total_penalty = list.total_penalty_value(ranking_configuration)
```

### Testing Approach
- Created comprehensive test suite with 31 tests covering all validations, associations, scopes, and methods
- Used descriptive fixture names and checked actual fixture files before referencing
- Tested STI subclasses, enum functionality, and dynamic penalty calculations
- All tests pass with 100% coverage of public methods

### Performance Considerations
- Added database indexes on frequently queried fields (type, dynamic_type)
- Used STI instead of polymorphic associations for better performance
- Unique constraints prevent duplicate penalty applications and list penalties

### Future Improvements
- Add more dynamic penalty types with complex logic
- Implement penalty templates for common scenarios
- Add bulk penalty application functionality
- Create penalty analytics and reporting features

### Lessons Learned
- Always check actual fixture names before referencing them in tests
- Rails 8 enum syntax requires the colon prefix
- STI validation logic needs to check the type field first, then validate media_type consistency
- Comprehensive documentation helps both humans and AI agents understand the system

### Related PRs
- Penalty model implementation with full test coverage
- Integration with existing RankingConfiguration and List models
- Avo admin interface updates

### Documentation Updated
- [x] Created `docs/models/penalty.md` with complete model documentation
- [x] Created `docs/models/penalty_application.md` with complete model documentation  
- [x] Created `docs/models/list_penalty.md` with complete model documentation
- [x] Updated `docs/testing.md` with fixture best practices
- [x] Updated `docs/todo.md` to mark task as completed
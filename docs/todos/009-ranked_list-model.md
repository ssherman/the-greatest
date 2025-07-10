# 009 - Ranked List Model Implementation

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-07-10
- **Started**: 
- **Completed**: 
- **Developer**: Shane

## Overview
Create the RankedList model to represent lists that are included in ranking configurations. This model acts as a junction table between RankingConfiguration and List models, with a weight field to control the influence of each list in the ranking algorithm.

## Context
- Ranking configurations need to include multiple lists with different weights
- Lists are media-specific (Books::List, Movies::List, etc.) and should be validated against the ranking configuration's media type
- The model needs to ensure type consistency between the ranking configuration and the list
- This is a core component of the ranking system that determines which lists contribute to rankings

## Requirements
- [ ] Create RankedList model with proper associations
- [ ] Implement polymorphic association with List models
- [ ] Add weight field for ranking influence
- [ ] Validate list type matches ranking configuration type
- [ ] Ensure unique list per ranking configuration
- [ ] Add proper validations and constraints
- [ ] Create comprehensive tests

## Technical Approach

### Database Schema
```sql
CREATE TABLE ranked_lists (
  id BIGSERIAL PRIMARY KEY,
  weight INTEGER, -- Nullable, set after penalty calculations
  list_id BIGINT NOT NULL,
  list_type VARCHAR NOT NULL, -- For polymorphic association
  ranking_configuration_id BIGINT NOT NULL,
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL,
  
  -- Constraints
  UNIQUE(list_id, list_type, ranking_configuration_id),
  FOREIGN KEY (ranking_configuration_id) REFERENCES ranking_configurations(id)
);
```

### Model Structure
- `RankedList` model with polymorphic association to List
- `belongs_to :list, polymorphic: true`
- `belongs_to :ranking_configuration`
- Custom validation to ensure list type matches ranking configuration type

### Key Features
1. **Polymorphic Association**: Supports different media-specific List types
2. **Type Validation**: Ensures list type matches ranking configuration type
3. **Weight System**: Controls influence of each list in rankings
4. **Uniqueness**: Prevents duplicate lists in same ranking configuration

## Dependencies
- RankingConfiguration model must exist
- List models (Books::List, Movies::List, etc.) must exist
- Polymorphic association support

## Acceptance Criteria
- [ ] Can associate lists with ranking configurations
- [ ] Can set weight for each list
- [ ] Validates list type matches ranking configuration type
- [ ] Prevents duplicate lists in same ranking configuration
- [ ] Supports all media types (Books, Movies, Games, Music)
- [ ] Proper error messages for validation failures

## Design Decisions

### Polymorphic vs Regular Association
**Decision**: Use polymorphic association
**Reasoning**: 
- Lists are media-specific (Books::List, Movies::List, etc.)
- Need to validate type consistency
- Follows Rails conventions for polymorphic relationships
- Allows for media-specific list behavior if needed

### Type Validation Strategy
- Validate that `list_type` matches the ranking configuration's STI type
- Example: Books::RankingConfiguration should only accept Books::List

### Weight Field
- Integer field for ranking influence (nullable)
- Initially null until penalties are calculated
- Will be set by penalty calculation system (future model)
- Could be positive or negative for different effects

---

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Approach Taken

### Key Files Changed

### Challenges Encountered

### Deviations from Plan

### Code Examples

### Testing Approach

### Performance Considerations

### Future Improvements

### Lessons Learned

### Related PRs

### Documentation Updated
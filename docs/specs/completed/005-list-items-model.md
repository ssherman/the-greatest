# 005 - List Items Model Implementation

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-01-27
- **Started**: 2025-07-06
- **Completed**: 2025-07-06
- **Developer**: 

## Overview
Implement the ListItem model that connects items (books, movies, music, games) to lists using polymorphic associations. This is a critical junction table that enables the core functionality of aggregating and ranking content across all media domains.

## Context
- ListItems serve as the junction table between Lists and the actual content items
- The existing schema was book-specific, but we need to support all media types
- Polymorphic associations will allow any media type to be included in any list
- This enables cross-media list aggregation and ranking functionality

## Requirements
- [ ] Create ListItem model with polymorphic associations
- [ ] Design database schema with appropriate indexes and constraints
- [ ] Implement polymorphic belongs_to associations
- [ ] Add validation rules for data integrity
- [ ] Create service objects for list item management
- [ ] Add comprehensive test coverage following namespacing requirements
- [ ] Update List model with has_many association

## Technical Approach

### Database Schema
Based on the existing list_items model, we'll create a streamlined polymorphic schema:

```ruby
# Core fields to include:
- id (primary key)
- list_id (bigint, not null) - Foreign key to lists table
- listable_type (string, not null) - Polymorphic type (e.g., "Books::Book", "Movies::Movie")
- listable_id (bigint, not null) - Polymorphic foreign key
- position (integer) - Ordering within the list
- created_at/updated_at
```

### Polymorphic Associations
```ruby
# ListItem model
class ListItem < ApplicationRecord
  belongs_to :list
  belongs_to :listable, polymorphic: true
end

# List model (update)
class List < ApplicationRecord
  has_many :list_items, dependent: :destroy
end

# Media models (future)
class Books::Book < ApplicationRecord
  has_many :list_items, as: :listable, dependent: :destroy
end
```

### Database Indexes
- `index_list_items_on_list_id` - For list queries
- `index_list_items_on_listable_type_and_listable_id` - For polymorphic queries
- `index_list_items_on_list_id_and_position` - For ordered list queries
- `index_list_items_on_list_id_and_listable_type_and_listable_id` - Unique constraint

## Dependencies
- List model (completed)
- Database configuration (completed)
- Media models (Books::Book, Movies::Movie, etc.) - will be created separately

## Acceptance Criteria
- [ ] ListItem model can be created and saved with required fields
- [ ] Polymorphic associations work correctly with different media types
- [ ] Database indexes are created for performance-critical queries
- [ ] Unique constraint prevents duplicate items in same list
- [ ] All validations pass for data integrity
- [ ] Tests cover all public methods with 100% coverage
- [ ] List model has proper has_many association

## Design Decisions
- **Polymorphic over separate tables**: Allows flexible association system for different media types
- **Position field**: Enables ordered lists and ranking functionality
- **Unique constraint**: Prevents duplicate items in the same list
- **Dependent destroy**: Ensures cleanup when lists or items are deleted
- **Streamlined schema**: Removed pending_book_data as it's no longer needed

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
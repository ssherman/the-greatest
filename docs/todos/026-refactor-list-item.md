# 026 - Refactor ListItem for Unverified Items

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-08-27
- **Started**: 2025-08-27
- **Completed**: 2025-08-27
- **Developer**: AI Assistant 

## Overview
Refactor the ListItem model to support storing list items that don't yet have a concrete Item associated with them. This will enable importing raw list data with metadata before manually verifying and linking to actual items in our database.

## Context
- Currently ListItem requires a polymorphic association to a concrete item (Book, Album, Movie, etc.)
- When importing lists from external sources, we often have metadata (title, author, etc.) but no corresponding item in our database yet
- We need a way to store these "unverified" list items with their metadata for manual verification later
- This supports the data import workflow where we capture everything first, then verify and link items

## Requirements
- [x] Make listable_type and listable_id optional/nullable in database and model
- [x] Add metadata JSONB field to store item information (title, author, artist, etc.)
- [x] Add verified boolean field that defaults to false
- [x] Update all existing tests to handle the new optional associations
- [x] Add scope `with_listable` that returns list_items that have a listable association
- [x] Add scope `without_listable` that returns list_items where listable is null (unverified items)
- [x] Update ListItem Avo resource to display metadata on the show page
- [x] Update ListItem Avo resource to include verified field on all views
- [x] Update model documentation to reflect new functionality

## Technical Approach
1. **Database Migration**: 
   - Make listable_type and listable_id nullable
   - Add metadata JSONB column
   - Add verified boolean column with default false
   
2. **Model Updates**:
   - Update validations to make listable optional
   - Add new scopes for verified/unverified items
   - Add methods to work with metadata
   
3. **Avo Resource Updates**:
   - Add metadata display to show page
   - Add verified field to index and form views
   
4. **Test Updates**:
   - Update existing tests to handle optional listable
   - Add new tests for unverified items functionality

## Dependencies
- None - this is a self-contained model refactor

## Acceptance Criteria
- [x] ListItem can be created without a listable association
- [x] Metadata can be stored and retrieved as structured JSON
- [x] Verified field properly tracks verification status
- [x] Scopes correctly filter verified vs unverified items
- [x] All existing tests pass with updated model
- [x] Avo interface displays new fields appropriately
- [x] Model follows Rails conventions and project coding standards

## Design Decisions
- Use JSONB for metadata to allow flexible storage of different media type attributes
- Default verified to false to ensure manual verification is required
- Keep polymorphic association optional rather than replacing it entirely
- Maintain backward compatibility with existing list items

---

## Implementation Notes

### Approach Taken
Successfully refactored the ListItem model to support unverified items with the following implementation:

1. **Database Migration**: Created migration to make `listable_type` and `listable_id` nullable, added `metadata` JSONB field and `verified` boolean field
2. **Model Updates**: Made polymorphic association optional, removed validation requirements for listable, added new scopes
3. **Test Updates**: Updated all tests to handle optional listable associations, added comprehensive tests for new functionality
4. **Avo Resource**: Enhanced admin interface to display metadata and verified status
5. **Documentation**: Updated model documentation with new features and usage examples

### Key Files Changed
- `db/migrate/20250828032452_refactor_list_item_for_unverified_items.rb` - Database schema changes
- `app/models/list_item.rb` - Model refactor with optional associations and new scopes
- `test/models/list_item_test.rb` - Updated and expanded test coverage
- `test/fixtures/list_items.yml` - Added fixtures for unverified items
- `app/avo/resources/list_item.rb` - Enhanced admin interface
- `docs/models/list_item.md` - Updated documentation

### Challenges Encountered
- Initial approach included complex validation to require either listable or metadata, but simplified to just allow optional listable per user feedback
- Needed to ensure uniqueness constraint works properly with nullable listable_id values

### Deviations from Plan
- Removed the validation that required either listable or metadata to be present, making the model simpler
- Removed unnecessary database indexes on metadata and verified fields per user feedback

### Code Examples
```ruby
# Create unverified item with metadata only
ListItem.create!(
  list: list,
  metadata: { title: "Book Title", author: "Author Name" },
  verified: false
)

# New scopes for filtering
ListItem.with_listable    # Items with associations
ListItem.without_listable # Items without associations  
ListItem.verified         # Verified items
ListItem.unverified       # Unverified items
```

### Testing Approach
- Updated existing tests to handle optional listable associations
- Added comprehensive tests for new scopes and unverified item functionality
- Added fixtures for both verified and unverified items
- Tested edge cases like duplicate prevention with nil listable_id

### Performance Considerations
- JSONB metadata field provides efficient storage and querying capabilities
- Existing indexes remain effective for verified items
- No additional indexes needed for basic filtering operations

### Future Improvements
- Could add validation for required metadata fields based on media type
- Could add methods to help with verification workflow (e.g., `verify_with_listable!`)
- Could add scopes for specific metadata queries

### Lessons Learned
- Simplicity is better than complex validation logic
- Optional associations in Rails work seamlessly when properly configured
- JSONB provides flexible metadata storage without performance penalty

### Related PRs
- N/A - Direct implementation without PR workflow

### Documentation Updated
- [x] Class documentation files updated (docs/models/list_item.md)
- [x] Model annotations updated via Rails annotate
- [x] Test fixtures updated with new schema
- [x] Todo documentation completed

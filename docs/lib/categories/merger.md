# Categories::Merger

## Summary
Service object for merging two categories by transferring all item associations and preserving alternative names. Handles complex merge operations with database transaction safety.

## Public Methods

### `#initialize(category:, category_to_merge_with:)`
Creates a new merger instance
- Parameters:
  - `category` (Category) - The source category to merge from
  - `category_to_merge_with` (Category) - The target category to merge into

### `#merge`
Performs the merge operation
- Returns: Category (the target category after merge)
- Side effects: Transfers items, updates alternative names, soft deletes source

## Private Methods

### `#merge_category_items`
Transfers all category items from source to target category
- Side effects: Creates new CategoryItem associations, handles duplicates

### `#update_alternative_names`
Adds source category name to target's alternative names
- Side effects: Updates target category's alternative_names array

### `#soft_delete_source_category`
Soft deletes the source category after successful merge
- Side effects: Calls Categories::Deleter to soft delete source

## Dependencies
- Category model
- CategoryItem model
- Categories::Deleter service
- Database transaction support

## Usage Examples
```ruby
# Merge two categories
merger = Categories::Merger.new(
  category: old_rock_category,
  category_to_merge_with: main_rock_category
)
result = merger.merge

# The target category now contains all items from both
result.category_items.count # Combined count
result.alternative_names # Includes old category name
```

## Error Handling
- Uses database transactions for rollback on failure
- Handles duplicate item associations gracefully
- Preserves data integrity during complex operations

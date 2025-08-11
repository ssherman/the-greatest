# Categories::Deleter

## Summary
Service object for deleting categories with support for both soft and hard deletion. Handles cleanup of associated category items and maintains data integrity through database transactions.

## Public Methods

### `#initialize(category:, soft: true)`
Creates a new deleter instance
- Parameters:
  - `category` (Category) - The category to delete
  - `soft` (Boolean) - Whether to soft delete (default: true)

### `#delete`
Performs the deletion operation
- Returns: void
- Side effects: Updates category and associated records

## Private Methods

### `#soft_delete`
Performs soft deletion by setting `deleted: true` and destroying category items
- Side effects: Updates category.deleted, destroys category_items

### `#hard_delete`
Performs hard deletion by calling `destroy` on the category
- Side effects: Removes category and all associated records from database

## Dependencies
- Category model
- CategoryItem model
- Database transaction support

## Usage Examples
```ruby
# Soft delete a category (default)
deleter = Categories::Deleter.new(category: rock_category)
deleter.delete

# Hard delete a category
deleter = Categories::Deleter.new(category: rock_category, soft: false)
deleter.delete
```

## Error Handling
- Uses database transactions for data consistency
- Handles both soft and hard deletion scenarios
- Maintains referential integrity

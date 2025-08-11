# Categories::Updater

## Summary
Service object for updating categories with sophisticated handling of name changes. Automatically detects existing categories with same name and merges them, or creates new categories with alternative name tracking.

## Public Methods

### `#initialize(category:, attributes:)`
Creates a new updater instance
- Parameters:
  - `category` (Category) - The category to update
  - `attributes` (Hash) - The attributes to update

### `#update`
Performs the update operation
- Returns: Category (the updated or newly created category)
- Side effects: May create new categories, merge existing ones, or update in place

## Private Methods

### `#handle_name_change`
Handles complex name change scenarios
- Returns: Category (new or merged category)
- Side effects: May create new categories or merge with existing ones

### `#simple_update`
Performs simple attribute updates without name changes
- Returns: Category (the updated category)

### `#find_existing_category_with_same_name`
Finds existing category with same name (case insensitive)
- Returns: Category or nil

### `#create_renamed_category`
Creates new category with updated name and old name in alternatives
- Returns: Category (newly created category)
- Side effects: Transfers items, soft deletes original

### `#merge_with_existing_category`
Merges with existing category of same name
- Returns: Category (the existing category after merge)

### `#transfer_category_items_to(target_category)`
Transfers all items from current category to target
- Parameters: `target_category` (Category) - The target to transfer items to
- Side effects: Creates new CategoryItem associations

## Dependencies
- Category model
- CategoryItem model
- Categories::Deleter service
- Categories::Merger service
- Database transaction support

## Usage Examples
```ruby
# Simple update (no name change)
updater = Categories::Updater.new(
  category: rock_category,
  attributes: { description: "Updated description" }
)
result = updater.update

# Name change to new name
updater = Categories::Updater.new(
  category: rock_category,
  attributes: { name: "Rock Music" }
)
result = updater.update # Creates new category with old name in alternatives

# Name change to existing name
updater = Categories::Updater.new(
  category: rock_category,
  attributes: { name: "Existing Category" }
)
result = updater.update # Merges with existing category
```

## Error Handling
- Uses database transactions for rollback on failure
- Handles complex name change scenarios gracefully
- Preserves data integrity during category operations

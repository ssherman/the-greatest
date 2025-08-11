# CategoryItem

## Summary
Polymorphic join model connecting categories to items across all media types. Handles the many-to-many relationship between categories and content items with automatic counter cache updates.

## Associations
- `belongs_to :category, counter_cache: :item_count` - The category this item belongs to
- `belongs_to :item, polymorphic: true` - The categorized item (album, song, artist, movie, etc.)

## Public Methods
None - this is primarily a join model with minimal business logic.

## Validations
- `category_id` - uniqueness scoped to `[:item_type, :item_id]` (prevents duplicate associations)

## Scopes
- `for_item_type(type)` - Filter by item type (e.g., "Music::Album")
- `for_category_type(category_type)` - Filter by category STI type (e.g., "Music::Category")

## Constants
None

## Callbacks
- `after_create :increment_category_item_count` - Updates category's item_count via counter_cache
- `after_destroy :decrement_category_item_count` - Updates category's item_count via counter_cache

## Dependencies
- Rails counter_cache for automatic item count maintenance
- Polymorphic associations for multi-media support

## Usage Examples
```ruby
# Associate an album with a category
CategoryItem.create!(category: rock_category, item: album)

# Find all items in a category
category.category_items.map(&:item)

# Find all categories for an item
album.category_items.map(&:category)
```

# ListItem

## Summary
Represents an item within a list. Junction table that connects lists to their content items using optional polymorphic associations. Enables the core functionality of aggregating and ranking content across all media domains (books, movies, music, games). Supports both verified items with concrete associations and unverified items with metadata only for data import workflows.

## Associations
- `belongs_to :list` - The list that contains this item
- `belongs_to :listable, polymorphic: true, optional: true` - The content item (can be any media type, optional for unverified items)

## Public Methods
No custom public methods defined. Inherits standard ActiveRecord methods.

## Validations
- `list` - presence required
- `position` - numericality greater than 0, allows blank
- `listable_id` - uniqueness scoped to list_id and listable_type (prevents duplicate items in same list), allows nil

## Scopes
- `ordered` - Returns items ordered by position
- `by_list(list)` - Returns items for a specific list
- `by_listable_type(type)` - Returns items of a specific media type
- `with_listable` - Returns items that have a listable association (verified items)
- `without_listable` - Returns items without a listable association (unverified items)
- `verified` - Returns items marked as verified
- `unverified` - Returns items marked as unverified

## Constants
None defined.

## Callbacks
None defined.

## Dependencies
- Rails polymorphic association functionality
- List model for the belongs_to association

## Database Schema
- `id` - Primary key
- `list_id` - Foreign key to lists table (bigint, not null)
- `listable_type` - Polymorphic type (string, nullable)
- `listable_id` - Polymorphic foreign key (bigint, nullable)
- `position` - Ordering within the list (integer)
- `metadata` - JSONB field for storing item information before verification
- `verified` - Boolean flag indicating if item has been manually verified (default: false)
- `created_at` - Creation timestamp
- `updated_at` - Update timestamp

## Polymorphic Associations
The ListItem model supports polymorphic associations with any media type:

### Supported Media Types
- `Books::Book` - Books content
- `Movies::Movie` - Movies content
- `Music::Album` - Music content
- `Games::Game` - Games content

### Database Indexes
- `index_list_items_on_list_id` - For list queries
- `index_list_items_on_listable_type_and_listable_id` - For polymorphic queries
- `index_list_items_on_list_id_and_position` - For ordered list queries
- `index_list_items_on_list_id_and_listable_type_and_listable_id` - Unique constraint

## Usage Examples
```ruby
# Create a verified list item for a music album
album = Music::Album.first
list = List.first
list_item = ListItem.create!(
  list: list,
  listable: album,
  position: 1,
  verified: true
)

# Create an unverified list item with metadata only
unverified_item = ListItem.create!(
  list: list,
  metadata: {
    title: "The Great Gatsby",
    author: "F. Scott Fitzgerald",
    year: 1925,
    isbn: "978-0-7432-7356-5"
  },
  position: 2,
  verified: false
)

# Query items by list
list_items = ListItem.by_list(list)

# Query verified vs unverified items
verified_items = ListItem.verified
unverified_items = ListItem.unverified

# Query items with or without listable associations
items_with_associations = ListItem.with_listable
items_without_associations = ListItem.without_listable

# Query items by media type
music_items = ListItem.by_listable_type("Music::Album")

# Get ordered items
ordered_items = list.list_items.ordered

# Check for duplicate items (only applies when listable is present)
duplicate = ListItem.new(
  list: list,
  listable: album
)
duplicate.valid? # => false (duplicate in same list)

# Multiple unverified items are allowed in the same list
unverified_item2 = ListItem.create!(
  list: list,
  metadata: { title: "Another Book", author: "Another Author" }
)
unverified_item2.valid? # => true (no listable_id conflict)
```

## Fixture Syntax
Rails polymorphic fixtures use the target type syntax:
```yaml
# Verified item with listable association
basic_item:
  list: basic_list
  listable: dark_side_of_the_moon (Music::Album)
  position: 1
  verified: true

# Unverified item with metadata only
unverified_item:
  list: basic_list
  metadata: { title: "Unknown Album", artist: "Unknown Artist" }
  position: 2
  verified: false
``` 
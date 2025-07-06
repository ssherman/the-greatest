# ListItem

## Summary
Represents an item within a list. Junction table that connects lists to their content items using polymorphic associations. Enables the core functionality of aggregating and ranking content across all media domains (books, movies, music, games).

## Associations
- `belongs_to :list` - The list that contains this item
- `belongs_to :listable, polymorphic: true` - The content item (can be any media type)

## Public Methods
No custom public methods defined. Inherits standard ActiveRecord methods.

## Validations
- `list` - presence required
- `listable` - presence required (polymorphic association)
- `position` - numericality greater than 0, allows blank
- `listable_id` - uniqueness scoped to list_id and listable_type (prevents duplicate items in same list)

## Scopes
- `ordered` - Returns items ordered by position
- `by_list(list)` - Returns items for a specific list
- `by_listable_type(type)` - Returns items of a specific media type

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
- `listable_type` - Polymorphic type (string, not null)
- `listable_id` - Polymorphic foreign key (bigint, not null)
- `position` - Ordering within the list (integer)
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
# Create a list item for a music album
album = Music::Album.first
list = List.first
list_item = ListItem.create!(
  list: list,
  listable: album,
  position: 1
)

# Create a list item for a movie
movie = Movies::Movie.first
list_item = ListItem.create!(
  list: list,
  listable: movie,
  position: 2
)

# Query items by list
list_items = ListItem.by_list(list)

# Query items by media type
music_items = ListItem.by_listable_type("Music::Album")

# Get ordered items
ordered_items = list.list_items.ordered

# Check for duplicate items
duplicate = ListItem.new(
  list: list,
  listable: album
)
duplicate.valid? # => false (duplicate in same list)
```

## Fixture Syntax
Rails polymorphic fixtures use the target type syntax:
```yaml
basic_item:
  list: basic_list
  listable: dark_side_of_the_moon (Music::Album)
  position: 1
``` 
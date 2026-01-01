# Admin::ListItemsController

## Summary
Generic controller for managing list items across all list types (albums, songs, and future domains). Provides CRUD operations for adding, updating, and removing items from lists, plus bulk deletion.

## Inheritance
Inherits from `Admin::BaseController` (requires admin authentication).

## Routes
| Verb | Path | Action | Purpose |
|------|------|--------|---------|
| GET | /admin/list/:list_id/list_items | index | Display list items for a list |
| POST | /admin/list/:list_id/list_items | create | Add item to list |
| PATCH | /admin/list_items/:id | update | Update item position/metadata |
| DELETE | /admin/list_items/:id | destroy | Remove single item from list |
| DELETE | /admin/list/:list_id/list_items/destroy_all | destroy_all | Remove all items from list |

> Source of truth: `config/routes.rb:225-235`

## Public Methods

### `index`
Displays all list items for a given list.
- Loads items with `includes(:listable)` to prevent N+1
- Orders by position
- Renders without layout (for Turbo Frame)

### `create`
Adds a new item to a list.
- Parameters: `listable_id`, `listable_type`, `position`, `metadata`, `verified`
- Returns Turbo Stream with flash, list refresh, and modal refresh
- Validates media type compatibility with list type

### `update`
Updates an existing list item.
- Parameters: `position`, `metadata`, `verified`
- Returns Turbo Stream with flash and list refresh

### `destroy`
Removes a single item from a list.
- Returns Turbo Stream with flash, list refresh, and modal refresh

### `destroy_all`
Removes all items from a list in a single transaction.
- Wraps deletion in `ActiveRecord::Base.transaction`
- Returns flash notice with count of deleted items
- Handles `ActiveRecord::RecordNotDestroyed` with error flash
- Redirects to appropriate list show page based on list type

## Private Methods

### `set_list`
Finds list by `params[:list_id]`. Used for `index`, `create`, `destroy_all`.

### `set_list_item`
Finds list item by `params[:id]`. Used for `update`, `destroy`.

### `redirect_path`
Determines correct redirect path based on list class:
- `Music::Albums::List` -> `admin_albums_list_path`
- `Music::Songs::List` -> `admin_songs_list_path`
- Default -> `music_root_path`

## Response Formats
- **Turbo Stream**: Primary format for AJAX operations, updates multiple page regions
- **HTML**: Fallback format with redirect and flash message

## Turbo Stream Targets
- `flash` - Flash message area
- `list_items_list` - List items container
- `add_item_to_list_modal` - Modal for adding items (refreshed after create/destroy)

## Dependencies
- `Admin::AddItemToListModalComponent` - ViewComponent for add item modal
- `ListItem` model
- `List` model (polymorphic base)

## Related Files
- View: `app/views/admin/list_items/index.html.erb`
- Test: `test/controllers/admin/list_items_controller_test.rb`

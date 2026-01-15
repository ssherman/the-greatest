# Admin::CategoryItemsController

## Summary
Generic cross-domain controller for managing CategoryItem join table associations. Handles adding and removing categories from items (Artists, Albums, Songs) across all media types (Music, Books, Movies, Games). Uses Turbo Streams for real-time UI updates without full page reloads.

## Inheritance
Inherits from `Admin::BaseController`, which provides admin authentication and authorization.

## Actions

### `#index`
Displays all categories currently assigned to an item.
- **Before Action**: `set_item`
- **Response**: Renders without layout (partial for Turbo Stream replacement)
- **Query**: Eager loads categories via `.includes(:category)`, orders by category name
- **Usage**: Called via lazy-loaded Turbo Frame to fetch categories list

### `#create`
Adds a category to an item.
- **Before Action**: `set_item`
- **Parameters**: `category_id` (via `category_item_params`)
- **Response**:
  - Success: Returns 3 Turbo Streams (flash notice, updated categories list, refreshed modal)
  - Failure: Returns error flash via Turbo Stream with `:unprocessable_entity` status
- **Side Effects**:
  - Reloads item after save to ensure fresh data
  - Counter cache on Category (`item_count`) is automatically updated
  - Search reindexing is queued via CategoryItem callbacks
- **Validation**: Enforced by CategoryItem model (uniqueness per item)

### `#destroy`
Removes a category from an item.
- **Before Action**: `set_category_item`
- **Response**: Returns 3 Turbo Streams (flash notice, updated categories list, refreshed modal)
- **Side Effects**:
  - Reloads item after destroy to ensure fresh data
  - Counter cache on Category is automatically updated
  - Search reindexing is queued

## Private Methods

### `#set_item`
Finds and sets `@item` from route parameters.
- **Used By**: `index`, `create` actions
- **Supported Types**:
  - `params[:artist_id]` → `Music::Artist`
  - `params[:album_id]` → `Music::Album`
  - `params[:song_id]` → `Music::Song`
  - Future: `params[:book_id]`, `params[:movie_id]`, `params[:game_id]`

### `#set_category_item`
Finds and sets `@category_item` from `params[:id]`.
- **Used By**: `destroy` action

### `#category_item_params`
Strong parameters for CategoryItem creation.
- **Permitted**: `category_id`
- **Returns**: Hash with whitelisted attributes

### `#redirect_path`
Determines the correct redirect path based on item class.
- **Logic**: Pattern matches on `@item.class.name` to route to appropriate admin show page
- **Supported Types**:
  - `Music::Artist` → `admin_artist_path`
  - `Music::Album` → `admin_album_path`
  - `Music::Song` → `admin_song_path`
  - Future: `Books::Book`, `Movies::Movie`, `Games::Game`
  - Fallback → `admin_root_path`
- **Returns**: String URL path

## Turbo Stream Pattern

All actions respond to both `turbo_stream` and `html` formats. The Turbo Stream responses replace three key elements:

1. **Flash Messages** (`#flash`) - Shows success/error notifications
2. **Categories List** (`#category_items_list`) - Updates the displayed categories
3. **Add Modal** (`#add_category_modal`) - Refreshes modal component

This pattern enables real-time updates without page reloads while maintaining fallback HTML responses.

## Routes
- `GET /admin/artists/:artist_id/category_items` → `index`
- `POST /admin/artists/:artist_id/category_items` → `create`
- `GET /admin/albums/:album_id/category_items` → `index`
- `POST /admin/albums/:album_id/category_items` → `create`
- `DELETE /admin/category_items/:id` → `destroy`

Note: Routes are nested under each item type for index/create, but destroy is a standalone route.

## Dependencies
- `CategoryItem` model - Polymorphic join table with counter cache and search integration
- `Admin::AddCategoryModalComponent` - ViewComponent for category selection modal
- `AutocompleteComponent` - For category search in modal
- Turbo Streams for reactive UI updates
- DaisyUI modal component for dialog UI

## Related Components
- `Admin::AddCategoryModalComponent` - Renders the category add form
- `Admin::Music::CategoriesController#search` - Provides autocomplete endpoint

## Cross-Domain Design
This controller is intentionally domain-agnostic:
- Works with any categorizable item type (Music::Artist, Music::Album, Music::Song, future Books/Movies/Games)
- Category filtering is handled by the search endpoint based on item's media type
- Uniqueness validation delegated to CategoryItem model
- Routing handled dynamically via `redirect_path` pattern matching

## Implementation Notes
- Controller follows the exact pattern of `Admin::ListPenaltiesController`
- Forward-compatible: Song, Book, Movie, Game support can be added by:
  1. Adding route
  2. Adding case to `set_item`
  3. Adding case to `redirect_path`
  4. Adding turbo frame to show page

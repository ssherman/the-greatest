# Admin::Music::Albums::ListsController

## Summary
Concrete controller for managing album lists in the admin interface. Inherits all CRUD operations from base controller and provides album-specific path helpers.

## Inheritance
- Inherits from: `Admin::Music::ListsController` (app/controllers/admin/music/lists_controller.rb:1)
- Pattern: Follows same structure as `Admin::Music::Albums::RankingConfigurationsController`

## Purpose
Provides album-specific routing and path generation while delegating all business logic to the base controller. This pattern enables code reuse across both album and song list management.

## Protected Methods

### `#list_class`
Returns: `::Music::Albums::List`

### `#lists_path`
Returns: `admin_albums_lists_path`

### `#list_path(list)`
Returns: `admin_albums_list_path(list)`

### `#new_list_path`
Returns: `new_admin_albums_list_path`

### `#edit_list_path(list)`
Returns: `edit_admin_albums_list_path(list)`

### `#param_key`
Returns: `:music_albums_list`

Strong parameters key for album list forms.

### `#items_count_name`
Returns: `"albums_count"`

SQL aggregation field name for counting list items.

### `#listable_includes`
Returns: `[:artists, :categories, :primary_image]`

Associations to eager load for album list items.

## Routes
All routes are nested under `/admin/albums/lists`:
- GET    `/admin/albums/lists` - index
- GET    `/admin/albums/lists/:id` - show
- GET    `/admin/albums/lists/new` - new
- POST   `/admin/albums/lists` - create
- GET    `/admin/albums/lists/:id/edit` - edit
- PATCH  `/admin/albums/lists/:id` - update
- DELETE `/admin/albums/lists/:id` - destroy

**Note:** These routes are defined BEFORE the main `resources :albums` to prevent slug conflicts.

## Dependencies
- Base controller: `app/controllers/admin/music/lists_controller.rb`
- Model: `app/models/music/albums/list.rb`
- Views: `app/views/admin/music/albums/lists/`

## Implementation History
- **Phase 8** (2025-11-14): Initial implementation
- **Phase 9** (2025-11-14): Enhanced with `param_key`, `items_count_name`, and `listable_includes` methods to support base controller abstraction

## Related Files
- Base controller: `app/controllers/admin/music/lists_controller.rb`
- Parallel implementation: `app/controllers/admin/music/songs/lists_controller.rb`
- Routes: `config/routes.rb` (line ~50, inside `namespace :albums`)
- Views: `app/views/admin/music/albums/lists/`

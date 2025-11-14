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

## Future Enhancement
When song lists are implemented, a parallel `Admin::Music::Songs::ListsController` will follow this same pattern.

## Related Files
- Base controller: `app/controllers/admin/music/lists_controller.rb`
- Routes: `config/routes.rb` (line ~50, inside `namespace :albums`)
- Views: `app/views/admin/music/albums/lists/`

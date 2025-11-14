# Admin::Music::Songs::ListsController

## Summary
Concrete controller for managing song lists in the admin interface. Inherits all CRUD operations from base controller and provides song-specific path helpers and configuration.

## Inheritance
- Inherits from: `Admin::Music::ListsController` (app/controllers/admin/music/lists_controller.rb:1)
- Pattern: Follows same structure as `Admin::Music::Albums::ListsController`

## Purpose
Provides song-specific routing, path generation, and configuration (param keys, count names, eager loading) while delegating all business logic to the base controller. This pattern enables code reuse across both album and song list management.

## Protected Methods

### `#list_class`
Returns: `::Music::Songs::List`

### `#lists_path`
Returns: `admin_songs_lists_path`

### `#list_path(list)`
Returns: `admin_songs_list_path(list)`

### `#new_list_path`
Returns: `new_admin_songs_list_path`

### `#edit_list_path(list)`
Returns: `edit_admin_songs_list_path(list)`

### `#param_key`
Returns: `:music_songs_list`

Strong parameters key for form submissions.

### `#items_count_name`
Returns: `"songs_count"`

Name of the SQL aggregation field used for counting list items in the index query.

### `#listable_includes`
Returns: `[:artists]`

Associations to eager load when fetching song list items. Simpler than albums (no categories or primary_image).

## Routes
All routes are nested under `/admin/songs/lists`:
- GET    `/admin/songs/lists` - index
- GET    `/admin/songs/lists/:id` - show
- GET    `/admin/songs/lists/new` - new
- POST   `/admin/songs/lists` - create
- GET    `/admin/songs/lists/:id/edit` - edit
- PATCH  `/admin/songs/lists/:id` - update
- DELETE `/admin/songs/lists/:id` - destroy

**Note:** These routes are defined BEFORE the main `resources :songs` to prevent slug conflicts (config/routes.rb:79).

## Dependencies
- Base controller: `app/controllers/admin/music/lists_controller.rb`
- Model: `app/models/music/songs/list.rb`
- Views: `app/views/admin/music/songs/lists/`

## Implementation Notes
Implemented in Phase 9 following the pattern established in Phase 8 (Album Lists). Required enhancement of base controller to support dynamic configuration via protected methods.

## Related Files
- Base controller: `app/controllers/admin/music/lists_controller.rb`
- Album lists controller: `app/controllers/admin/music/albums/lists_controller.rb` (parallel implementation)
- Routes: `config/routes.rb` (line 79, inside `namespace :songs`)
- Views: `app/views/admin/music/songs/lists/`
- Tests: `test/controllers/admin/music/songs/lists_controller_test.rb`

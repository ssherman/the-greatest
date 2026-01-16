# Admin::Music::ListsController

## Summary
Abstract base controller for managing music lists (albums and songs) in the admin interface. Provides shared CRUD operations, sorting, and pagination logic that subclasses inherit.

## Inheritance
- Inherits from: `Admin::Music::BaseController`
- Subclasses:
  - `Admin::Music::Albums::ListsController` (app/controllers/admin/music/albums/lists_controller.rb:6)
  - `Admin::Music::Songs::ListsController` (app/controllers/admin/music/songs/lists_controller.rb:6)

## Public Actions

### `#index`
Lists all lists with sorting, filtering, and pagination
- Query: Includes submitted_by user, left joins list_items for counting
- Filtering: By status (unapproved, approved, rejected, active) via `?status=` param
- Sorting: By id, name, year_published, or created_at (whitelisted)
- Pagination: 25 items per page via Pagy
- Sets `@selected_status` for view dropdown

### `#show`
Displays a single list with full details
- Includes: submitted_by, penalties, list_items (with eager-loaded associations via `listable_includes`)
- Performance: Uses `.includes()` to prevent N+1 queries
- Associations: Dynamic based on subclass (albums include artists/categories/images, songs include only artists)

### `#new`
Renders form for creating a new list

### `#create`
Creates a new list with form data
- Validates and parses items_json if submitted as JSON string
- Success: Redirects to show page
- Failure: Re-renders new form with 422 status

### `#edit`
Renders form for editing an existing list

### `#update`
Updates an existing list
- Validates and parses items_json if submitted as JSON string
- Success: Redirects to show page
- Failure: Re-renders edit form with 422 status

### `#destroy`
Deletes a list
- Redirects to index page after deletion

## Protected Methods (Abstract)

Subclasses must implement these configuration methods:

### `#list_class`
Returns the specific list class (e.g., `Music::Albums::List` or `Music::Songs::List`)

### `#lists_path`
Returns the index path (e.g., `admin_albums_lists_path` or `admin_songs_lists_path`)

### `#list_path(list)`
Returns the show path for a specific list

### `#new_list_path`
Returns the new form path

### `#edit_list_path(list)`
Returns the edit form path

### `#param_key`
Returns the strong parameters key for the list type (e.g., `:music_albums_list` or `:music_songs_list`)

Added in Phase 9 to support dynamic form parameter handling.

### `#items_count_name`
Returns the name for the SQL count aggregation (e.g., `"albums_count"` or `"songs_count"`)

Added in Phase 9 to support dynamic count field naming in index queries.

### `#listable_includes`
Returns the array of associations to eager load for list items (e.g., `[:artists, :categories, :primary_image]` for albums, `[:artists]` for songs)

Added in Phase 9 to support different eager loading strategies per list type.

## Private Methods

### `#load_lists_for_index`
Builds the query for the index page with filtering, sorting, and pagination
- Applies status filter via `apply_status_filter`
- Counts items via SQL aggregation (field name from `items_count_name`) to avoid N+1
- Applies sorting with whitelisted columns and directions

### `#apply_status_filter(scope)`
Filters lists by status
- Parameters: scope (ActiveRecord::Relation) - the base query
- Returns: Filtered scope or original scope if no filter applies
- Behavior:
  - Returns original scope if status param is blank or "all"
  - Returns original scope if status value is not a valid enum key
  - Otherwise filters to the specified status

### `#sortable_column(column)`
Whitelists sort columns
- Allowed: id, name, year_published, created_at
- Default: name

### `#sortable_direction(direction)`
Whitelists and normalizes sort direction
- Allowed: ASC, DESC (case insensitive)
- Default: ASC

### `#list_params`
Strong parameters for list creation/update

Uses `param_key` from subclass to support different form parameter structures (`:music_albums_list` vs `:music_songs_list`).

**Permitted Fields:**
- Basic: name, description, status, source, url, year_published
- Quality Metrics: number_of_voters, estimated_quality, num_years_covered
- Flags: high_quality_source, category_specific, location_specific, yearly_award, voter_count_estimated, voter_count_unknown, voter_names_unknown
- External IDs: musicbrainz_series_id
- Import Data: items_json, raw_html, simplified_html, formatted_text

**Note on items_json Validation:**
- JSON validation is handled at the model level (see `app/models/list.rb`)
- The model's `parse_items_json_if_string` callback automatically parses valid JSON strings
- The model's `items_json_format` validation catches invalid JSON and prevents 500 errors

## Security
- Inherits admin authentication from `Admin::Music::BaseController`
- SQL injection prevention via whitelisted sort columns/directions
- Strong parameters for mass assignment protection
- JSON parsing with error handling to prevent exceptions

## Performance Considerations
- Uses `.includes()` and `.left_joins()` to prevent N+1 queries
- SQL aggregation for item counts (albums/songs) instead of Ruby iteration
- Pagination limits query results to 25 per page
- Dynamic eager loading via `listable_includes` ensures only necessary associations are loaded

## Dependencies
- Pagy gem for pagination
- JSON parsing for items_json handling
- Strong parameters for security

## Implementation History
- **Phase 8** (2025-11-14): Initial implementation for album lists
- **Phase 9** (2025-11-14): Enhanced abstraction for song lists support
  - Added `param_key`, `items_count_name`, and `listable_includes` abstract methods
  - Made base controller truly reusable for different list types
- **Spec 116** (2026-01-16): Added status filtering
  - Added `apply_status_filter` method for filtering by list status
  - Index views updated with filter dropdown and combined name/source columns

## Related Files
- Base class: `app/controllers/admin/music/base_controller.rb`
- Subclasses:
  - `app/controllers/admin/music/albums/lists_controller.rb`
  - `app/controllers/admin/music/songs/lists_controller.rb`
- Views:
  - `app/views/admin/music/albums/lists/`
  - `app/views/admin/music/songs/lists/`
- Helper: `app/helpers/admin/music/lists_helper.rb`
- Model: `app/models/list.rb`
- Tests:
  - `test/controllers/admin/music/songs/lists_controller_test.rb`

# Admin::Music::ListsController

## Summary
Abstract base controller for managing music lists (albums and songs) in the admin interface. Provides shared CRUD operations, sorting, and pagination logic that subclasses inherit.

## Inheritance
- Inherits from: `Admin::Music::BaseController`
- Subclasses:
  - `Admin::Music::Albums::ListsController` (app/controllers/admin/music/albums/lists_controller.rb:6)
  - Future: `Admin::Music::Songs::ListsController`

## Public Actions

### `#index`
Lists all lists with sorting and pagination
- Query: Includes submitted_by user, left joins list_items for counting
- Sorting: By id, name, year_published, or created_at (whitelisted)
- Pagination: 25 items per page via Pagy

### `#show`
Displays a single list with full details
- Includes: submitted_by, penalties, list_items (with eager-loaded albums and artists)
- Performance: Uses `.includes()` to prevent N+1 queries

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

Subclasses must implement these path helper methods:

### `#list_class`
Returns the specific list class (e.g., `Music::Albums::List`)

### `#lists_path`
Returns the index path

### `#list_path(list)`
Returns the show path for a specific list

### `#new_list_path`
Returns the new form path

### `#edit_list_path(list)`
Returns the edit form path

## Private Methods

### `#load_lists_for_index`
Builds the query for the index page with sorting and pagination
- Counts albums via SQL aggregation to avoid N+1
- Applies sorting with whitelisted columns and directions

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
- SQL aggregation for album counts instead of Ruby iteration
- Pagination limits query results to 25 per page

## Dependencies
- Pagy gem for pagination
- JSON parsing for items_json handling
- Strong parameters for security

## Related Files
- Base class: `app/controllers/admin/music/base_controller.rb`
- Subclass: `app/controllers/admin/music/albums/lists_controller.rb`
- Views: `app/views/admin/music/albums/lists/`
- Helper: `app/helpers/admin/music/lists_helper.rb`
- Model: `app/models/list.rb`

# Admin::Music::ArtistsController

## Summary
Admin CRUD controller for Music::Artist management. Provides full create, read, update, delete operations plus search, pagination, and custom admin actions.

## Purpose
- Complete CRUD operations for Music::Artist records
- OpenSearch-powered search functionality
- Pagination with Pagy (25 items per page)
- Custom admin action execution (single, bulk, and index-level)
- Turbo Frame support for partial page updates

## Inheritance
Inherits from: `Admin::Music::BaseController`

## Before Actions
- `set_artist` (only: `[:edit, :update, :destroy, :execute_action]`)

## Routes
```ruby
# Inside domain constraint for Music
namespace :admin, module: "admin/music" do
  resources :artists do
    member { post :execute_action }
    collection do
      post :bulk_action
      post :index_action
      get :search
    end
  end
end
```

**Generated paths:**
- `admin_artists_path` → `/admin/artists`
- `admin_artist_path(@artist)` → `/admin/artists/:id`
- `execute_action_admin_artist_path(@artist)` → `/admin/artists/:id/execute_action`
- `bulk_action_admin_artists_path` → `/admin/artists/bulk_action`
- `index_action_admin_artists_path` → `/admin/artists/index_action`
- `search_admin_artists_path` → `/admin/artists/search`

## Public Actions

### `index`
Lists all artists with search, sort, and pagination.

**Parameters:**
- `q` (optional) - Search query string
- `sort` (optional) - Column to sort by (`id`, `name`, `kind`, `created_at`)

**Behavior:**
- **With search (`q` present):**
  - Calls `Search::Music::Search::ArtistGeneral.call(params[:q], size: 1000)`
  - Preserves OpenSearch relevance order using `in_order_of(:id, artist_ids)`
  - Paginates results with Pagy (25 per page)
- **Without search:**
  - Standard database query
  - Sorts by `params[:sort]` or defaults to `name`
  - Table-qualified sorting (`music_artists.id`, `music_artists.name`) to prevent ambiguity

**Performance Optimizations:**
- Eager loads `:categories` to prevent N+1 queries
- Uses SQL aggregate `COUNT(DISTINCT music_albums.id) as albums_count` for album counts
- Left joins albums table for count calculation

**View:** `app/views/admin/music/artists/index.html.erb`

### `show`
Displays single artist with all associations.

**Parameters:**
- `id` - Artist ID or slug

**Behavior:**
- Eager loads all associations to prevent N+1 queries:
  - `:categories, :identifiers, :primary_image`
  - `albums: [:primary_image]`
  - `:images`

**View:** `app/views/admin/music/artists/show.html.erb`

### `new`
Renders new artist form.

**View:** `app/views/admin/music/artists/new.html.erb`

### `create`
Creates new artist record.

**Parameters:**
- `music_artist[name]` - Required
- `music_artist[description]` - Optional
- `music_artist[kind]` - Enum (person/group)
- `music_artist[born_on]` - Date (for persons)
- `music_artist[year_died]` - Integer (for persons)
- `music_artist[year_formed]` - Integer (for groups)
- `music_artist[year_disbanded]` - Integer (for groups)
- `music_artist[country]` - 2-letter country code

**Success:** Redirects to show page with notice
**Failure:** Renders new form with :unprocessable_entity status

### `edit`
Renders edit artist form.

**View:** `app/views/admin/music/artists/edit.html.erb`

### `update`
Updates existing artist record.

**Parameters:** Same as `create`

**Success:** Redirects to show page with notice
**Failure:** Renders edit form with :unprocessable_entity status

### `destroy`
Deletes artist record.

**Behavior:**
- Uses `destroy!` to raise on failure
- Redirects to index with success notice
- Handles dependent records per model associations

### `execute_action` (member POST)
Executes a custom admin action on a single artist.

**Parameters:**
- `action_name` - Class name of action (e.g., `"RefreshArtistRanking"`)

**Behavior:**
- Constantizes action class: `"Actions::Admin::Music::#{params[:action_name]}"`
- Calls action with user and artist model
- Responds with Turbo Stream or HTML redirect

**Example:**
```ruby
post execute_action_admin_artist_path(@artist, action_name: "RefreshArtistRanking")
# => Executes Actions::Admin::Music::RefreshArtistRanking.call(user:, models: [@artist])
```

**Turbo Stream Response:**
Replaces `#flash` div with action result message

### `bulk_action` (collection POST)
Executes action on multiple selected artists.

**Parameters:**
- `action_name` - Class name of action
- `artist_ids[]` - Array of artist IDs

**Behavior:**
- Loads selected artists by IDs
- Executes action on collection
- Reloads full artist list with pagination (via `load_artists_for_index`)
- Updates both flash and table via Turbo Stream

**Turbo Stream Response:**
- Replaces `#flash` div with action result message
- Replaces `#artists_table` with updated table (includes pagy for pagination)

**Example:**
```ruby
post bulk_action_admin_artists_path(
  action_name: "GenerateArtistDescription",
  artist_ids: [1, 2, 3]
)
```

### `index_action` (collection POST)
Executes index-level action (no specific artists).

**Parameters:**
- `action_name` - Class name of action

**Behavior:**
- Calls action with empty models array
- Useful for global operations (e.g., "RefreshAllArtistsRankings")

**Example:**
```ruby
post index_action_admin_artists_path(
  action_name: "RefreshAllArtistsRankings"
)
```

### `search` (collection GET)
JSON autocomplete endpoint for artist search.

**Parameters:**
- `q` - Search query

**Returns:** JSON array
```json
[
  { "value": 123, "text": "The Beatles" },
  { "value": 456, "text": "Pink Floyd" }
]
```

**Behavior:**
- Calls OpenSearch with size limit of 10
- Preserves relevance order
- Returns empty array `[]` if no results (prevents `ArgumentError` from `in_order_of`)
- Used for autocomplete/typeahead components

**Error Handling:**
```ruby
# Guard against empty results
if artist_ids.empty?
  render json: []
  return
end
```
Without this guard, `in_order_of(:id, [])` would raise `ArgumentError`.

## Private Methods

### `set_artist`
Before action that loads the artist for member actions.

**Usage:**
```ruby
before_action :set_artist, only: [:edit, :update, :destroy, :execute_action]
```

### `load_artists_for_index`
Shared method that loads artists with search, sorting, pagination, and N+1 prevention.

**Behavior:**
- Checks for `params[:q]` to determine search vs. browse mode
- In search mode: Uses OpenSearch and preserves relevance order
- In browse mode: Applies sorting from `params[:sort]` via `sortable_column` whitelist
- Always includes categories and aggregates album counts
- Applies pagination with Pagy (25 items per page)

**Error Handling:**
Protects against empty search results:
```ruby
if artist_ids.empty?
  @artists = Music::Artist.none
else
  @artists = Music::Artist.in_order_of(:id, artist_ids)
end
```

Without this guard, searching for a nonexistent artist would cause:
- `in_order_of(:id, [])` raises `ArgumentError: empty order list`
- Results in 500 error instead of showing "No artists found" empty state

**Used by:**
- `index` action
- `bulk_action` turbo stream response (to refresh table)

**Why extracted:**
- DRY principle - shared logic between index and bulk_action
- Ensures consistent N+1 prevention across both actions
- Ensures consistent error handling for empty results
- Makes testing easier (can test the method directly)

### `sortable_column(column)`
Whitelists sortable columns to prevent SQL injection attacks.

**Parameters:**
- `column` (String) - The requested sort column from params

**Returns:** String - Table-qualified column name or default

**Whitelist:**
```ruby
{
  "id" => "music_artists.id",
  "name" => "music_artists.name",
  "kind" => "music_artists.kind",
  "created_at" => "music_artists.created_at"
}
```

**Security:**
- Prevents SQL injection by mapping user input to known-safe column names
- Returns default `"music_artists.name"` if invalid column requested
- Uses `Hash#fetch` with default to ensure safety
- Never interpolates user input directly into SQL

**Example:**
```ruby
sortable_column("name")          # => "music_artists.name"
sortable_column("id")            # => "music_artists.id"
sortable_column("invalid")       # => "music_artists.name" (default)
sortable_column("'; DROP TABLE") # => "music_artists.name" (safe!)

## Strong Parameters

### `artist_params`
Permitted attributes for create/update:
- `:name, :description, :kind`
- `:born_on, :year_died` (for persons)
- `:year_formed, :year_disbanded` (for groups)
- `:country`

## Search Integration

### OpenSearch Service
Uses existing `Search::Music::Search::ArtistGeneral` service:

**Features:**
- Name normalization (lowercasing, quote normalization)
- Match phrase queries (boost: 10.0)
- Match queries with operator:and (boost: 5.0)
- Keyword exact match (boost: 8.0)
- Returns: `[{ id:, score:, source: }]`

**Size Limits:**
- Index action: 1000 results (then paginated)
- Autocomplete: 10 results (JSON endpoint)

## Performance Optimizations

### N+1 Prevention
```ruby
# Index - SQL aggregate for album counts
@artists = Music::Artist
  .includes(:categories)
  .left_joins(:albums)
  .select("music_artists.*, COUNT(DISTINCT music_albums.id) as albums_count")
  .group("music_artists.id")

# Show - Nested eager loading
@artist = Music::Artist
  .includes(:categories, :identifiers, :primary_image, albums: [:primary_image], images: [])
  .find(params[:id])
```

### Qualified Sorting with Security
Prevents both PostgreSQL ambiguous column errors and SQL injection:
```ruby
# Whitelist prevents SQL injection
sort_column = sortable_column(params[:sort])

# Table-qualified column names prevent ambiguous column errors
allowed_columns = {
  "id" => "music_artists.id",
  "name" => "music_artists.name",
  "kind" => "music_artists.kind",
  "created_at" => "music_artists.created_at"
}
```

**Why both are needed:**
1. **Table qualification** - Required when using joins to prevent "ambiguous column" errors
2. **Whitelist validation** - Required to prevent SQL injection attacks from malicious sort parameters

## Turbo Frame Integration

### Frame: `artists_table`
Used in index view for partial updates:
- Search results update table only
- Sort links update table only
- Full-page navigation uses `data-turbo-frame="_top"`

**Example:**
```erb
<!-- Updates frame only -->
<%= link_to "Name", admin_artists_path(sort: :name),
            data: { turbo_frame: "artists_table" } %>

<!-- Full page navigation -->
<%= link_to "View", admin_artist_path(@artist),
            data: { turbo_frame: "_top" } %>
```

## Action Execution Pattern

### Available Actions
1. **GenerateArtistDescription** (bulk) - Queues AI description generation jobs
2. **RefreshArtistRanking** (single) - Recalculates one artist's ranking
3. **RefreshAllArtistsRankings** (index) - Recalculates all artist rankings

### Action Result Handling
```ruby
result = action_class.call(user: current_user, models: [@artist])
# => Returns Actions::Admin::BaseAction::ActionResult

result.success?  # => true/false
result.message   # => "Artist ranking calculation queued"
result.status    # => :success, :error, or :warning
```

## Dependencies
- **OpenSearch**: Search functionality via `Search::Music::Search::ArtistGeneral`
- **Pagy**: Pagination (25 items per page)
- **Turbo**: Turbo Frame partial updates
- **Actions**: Custom admin action classes in `Actions::Admin::Music::`

## Related Classes
- `Music::Artist` - Model being managed
- `Admin::Music::BaseController` - Parent controller
- `Actions::Admin::Music::*` - Admin action classes
- `Search::Music::Search::ArtistGeneral` - OpenSearch service

## Related Views
- `/app/views/admin/music/artists/index.html.erb`
- `/app/views/admin/music/artists/show.html.erb`
- `/app/views/admin/music/artists/new.html.erb`
- `/app/views/admin/music/artists/edit.html.erb`
- `/app/views/admin/music/artists/_form.html.erb`
- `/app/views/admin/music/artists/_table.html.erb`

## Testing
- Controller tests: `/test/controllers/admin/music/artists_controller_test.rb` (34 tests)
- Covers: CRUD operations, search, pagination, actions, authorization, SQL injection prevention, empty search results

### Error Handling Tests
Two specific tests verify empty search result handling:

1. **Empty Search Results in Index**
   ```ruby
   test "should handle empty search results without error" do
     # Mock OpenSearch returning empty results
     ::Search::Music::Search::ArtistGeneral.stubs(:call).returns([])

     # Should not raise ArgumentError from in_order_of
     assert_nothing_raised do
       get admin_artists_path(q: "nonexistentartist")
     end

     assert_response :success  # Shows "No artists found" empty state
   end
   ```

2. **Empty Autocomplete Results**
   ```ruby
   test "should return empty JSON array when search has no results" do
     ::Search::Music::Search::ArtistGeneral.stubs(:call).returns([])

     assert_nothing_raised do
       get search_admin_artists_path(q: "nonexistentartist"), as: :json
     end

     assert_response :success
     json_response = JSON.parse(response.body)
     assert_equal [], json_response  # Returns empty array, not 500
   end
   ```

### Security Tests
Two specific tests verify SQL injection protection:

1. **SQL Injection Attempt Test**
   ```ruby
   test "should reject invalid sort parameters and default to name" do
     # Attempts SQL injection via sort parameter
     get admin_artists_path(sort: "'; DROP TABLE music_artists; --")
     assert_response :success
     # Verifies table still exists (not dropped)
     assert ::Music::Artist.count > 0
   end
   ```

2. **Whitelist Validation Test**
   ```ruby
   test "should only allow whitelisted sort columns" do
     # Valid columns should work
     ["id", "name", "kind", "created_at"].each do |column|
       get admin_artists_path(sort: column)
       assert_response :success
     end

     # Invalid columns should default to name (no error)
     ["country", "description", "invalid", "music_artists.id; --"].each do |column|
       get admin_artists_path(sort: column)
       assert_response :success
     end
   end
   ```

## File Location
`/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/artists_controller.rb`

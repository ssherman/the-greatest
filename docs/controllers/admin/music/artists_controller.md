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
- Loads all artists by IDs
- Executes action on collection
- Updates both flash and table via Turbo Stream

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
- Used for autocomplete/typeahead components

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

### Qualified Sorting
Prevents PostgreSQL ambiguous column errors when joined:
```ruby
sort_column = params[:sort] == "id" ? "music_artists.id" : (params[:sort] || "music_artists.name")
```

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
- Controller tests: `/test/controllers/admin/music/artists_controller_test.rb` (30 tests)
- Covers: CRUD operations, search, pagination, actions, authorization

## File Location
`/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/artists_controller.rb`

# Admin::Music::SongsController

## Summary
Admin CRUD controller for Music::Song management. Provides full create, read, update, delete operations with OpenSearch integration, sortable columns, pagination, and custom action execution for admin and editor users.

**Location**: `app/controllers/admin/music/songs_controller.rb`

## Inheritance
Inherits from `Admin::Music::BaseController` which provides:
- Authentication (admin/editor roles required)
- Domain-specific layout
- Common admin helpers

## Actions

### Standard CRUD Actions

#### `#index`
Lists songs with search, sort, and pagination support.
- **OpenSearch Integration**: Uses `Search::Music::Search::SongGeneral` when `q` param present
- **Sorting**: Whitelist-validated columns (id, title, release_year, duration_secs, created_at)
- **Pagination**: 25 items per page via Pagy
- **N+1 Prevention**: Eager loads categories and song_artists with artists
- **Response**: HTML view with songs table, search bar, pagination controls

#### `#show`
Displays single song with all associations.
- **Eager Loading**: Deep includes for categories, identifiers, external_links, song_artists, tracks (with releases, albums, images), list_items, ranked_items
- **Response**: HTML view with comprehensive song details and action buttons

#### `#new`
Renders form for creating new song.
- **Response**: HTML form view

#### `#create`
Creates new song from form submission.
- **Params**: `song_params` (title, description, notes, duration_secs, release_year, isrc)
- **Success**: Redirects to song show page with success notice
- **Failure**: Re-renders new form with validation errors (422 status)

#### `#edit`
Renders form for editing existing song.
- **Response**: HTML form view with pre-populated values

#### `#update`
Updates song from form submission.
- **Params**: `song_params` (title, description, notes, duration_secs, release_year, isrc)
- **Success**: Redirects to song show page with success notice
- **Failure**: Re-renders edit form with validation errors (422 status)

#### `#destroy`
Permanently deletes song and cascades to associations.
- **Success**: Redirects to songs index with success notice
- **Cascade**: Deletes song_artists, tracks (if orphaned), list_items, ranked_items

### Custom Actions

#### `#execute_action`
Executes single-record custom action (e.g., MergeSong).
- **Member Route**: `POST /admin/songs/:id/execute_action`
- **Params**:
  - `action_name` (string, required) - Action class name (e.g., "MergeSong")
  - Additional fields specific to action
- **Action Resolution**: Dynamically instantiates `Actions::Admin::Music::#{action_name}`
- **Response**:
  - Turbo Stream: Replaces flash message
  - HTML Fallback: Redirects to song show with message

#### `#bulk_action`
Executes action on multiple songs (e.g., GenerateAIDescription).
- **Collection Route**: `POST /admin/songs/bulk_action`
- **Params**:
  - `song_ids[]` (array of integers, required) - Selected song IDs
  - `action_name` (string, required) - Action class name
- **Response**:
  - Turbo Stream: Replaces flash and songs table
  - HTML Fallback: Redirects to songs index with message

#### `#search`
Autocomplete endpoint for song selection (JSON).
- **Collection Route**: `GET /admin/songs/search`
- **Params**: `q` (string, required) - Search query
- **OpenSearch**: Uses `Search::Music::Search::SongGeneral` with size limit of 10
- **Response**: JSON array of `{value: song_id, text: "Title - Artist(s)"}`
- **Empty Query**: Returns empty array
- **Performance Target**: ≤300ms p95

## Private Methods

### `#set_song`
Before action for show, edit, update, destroy, execute_action.
- Loads `@song` from params[:id]
- Raises ActiveRecord::RecordNotFound if not found

### `#load_songs_for_index`
Loads songs for index action with search/sort/pagination.
- **Search Mode**: Uses OpenSearch when `q` param present, preserves relevance order with `in_order_of`
- **Browse Mode**: Standard ActiveRecord query with sortable columns
- **Empty Results**: Handles gracefully, prevents `in_order_of` errors
- **Size Limits**: 1000 results from OpenSearch, paginated to 25/page

### `#sortable_column(column)`
Whitelists and maps sort parameters to qualified column names.
- **Allowed**: id, title, release_year, duration_secs, created_at
- **Default**: title (if invalid column provided)
- **SQL Injection Prevention**: Whitelist-only, no user input directly in ORDER BY
- **Returns**: Fully-qualified column name (e.g., "music_songs.title")

### `#song_params`
Strong parameters for song creation/update.
- **Permitted**: title, description, notes, duration_secs, release_year, isrc
- **Required**: music_song namespace

## Routes

```ruby
resources :songs do
  member do
    post :execute_action
  end
  collection do
    post :bulk_action
    get :search
  end
end
```

**Generated Paths**:
- `admin_songs_path` → `/admin/songs` (index)
- `admin_song_path(@song)` → `/admin/songs/:id` (show)
- `new_admin_song_path` → `/admin/songs/new`
- `edit_admin_song_path(@song)` → `/admin/songs/:id/edit`
- `execute_action_admin_song_path(@song)` → `/admin/songs/:id/execute_action`
- `bulk_action_admin_songs_path` → `/admin/songs/bulk_action`
- `search_admin_songs_path` → `/admin/songs/search`

## Authorization
- **Required Roles**: admin or editor (enforced by `Admin::Music::BaseController`)
- **Redirect**: Non-authorized users redirected to `music_root_path`

## Dependencies
- **Models**: Music::Song, Music::Artist (via song_artists)
- **Search**: Search::Music::Search::SongGeneral (OpenSearch service)
- **Actions**: Actions::Admin::Music::* (dynamically loaded)
- **Pagination**: Pagy gem
- **Views**: app/views/admin/music/songs/

## Performance Considerations

### N+1 Query Prevention
**Index**:
```ruby
.includes(:categories, song_artists: [:artist])
```

**Show**:
```ruby
.includes(
  :categories,
  :identifiers,
  :external_links,
  song_artists: [:artist],
  tracks: {release: [:album, :primary_image]},
  list_items: [:list],
  ranked_items: [:ranking_configuration]
)
```

### Search Performance
- **Index search**: Fetches up to 1000 results from OpenSearch
- **Autocomplete search**: Limits to 10 results
- **Empty results**: Handled without database query

## Related Documentation
- **Model**: `docs/models/music/song.md`
- **Actions**:
  - `docs/lib/actions/admin/music/merge_song.md`
- **Base Controller**: `docs/controllers/admin/music/base_controller.md`
- **Search Service**: `docs/lib/search/music/search/song_general.md`
- **Implementation Spec**: `docs/specs/completed/075-custom-admin-phase-4-songs.md`

## Testing
**Test Location**: `test/controllers/admin/music/songs_controller_test.rb`
**Test Coverage**: 19 tests covering CRUD, search, sort, actions, authorization, N+1 prevention

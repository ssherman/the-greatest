# Admin::Music::AlbumsController

**Location:** `/web-app/app/controllers/admin/music/albums_controller.rb`

**Namespace:** Admin::Music

**Inherits From:** Admin::Music::BaseController

**Purpose:** Provides admin CRUD interface for Music::Album records with search, sorting, pagination, and custom actions.

## Overview

Part of the custom admin interface (Phase 2) that replaces Avo for album management. Implements full CRUD operations with OpenSearch integration for powerful search capabilities and two custom actions for AI description generation and album merging.

## Public Methods

### Standard CRUD Actions

#### `#index`
Displays paginated list of albums with search and sort capabilities.

**Features:**
- OpenSearch integration for search queries
- Sortable by: title, release_year, created_at
- 25 items per page
- Eager loads categories and artists to prevent N+1 queries
- Handles empty search results gracefully

**Parameters:**
- `q` (optional) - Search query string
- `sort` (optional) - Sort column (defaults to title)

**View:** `app/views/admin/music/albums/index.html.erb`

#### `#show`
Displays detailed view of a single album with all associations.

**Eager Loads:**
- Categories
- Identifiers
- Primary image
- External links
- Album artists with artists
- Releases with primary images
- Images
- Credits with artists

**View:** `app/views/admin/music/albums/show.html.erb`

#### `#new`
Renders form for creating a new album.

**View:** `app/views/admin/music/albums/new.html.erb`

#### `#create`
Creates a new album record.

**Parameters:**
- `music_album[title]` (required) - Album title
- `music_album[description]` (optional) - Album description
- `music_album[release_year]` (optional) - Release year

**Success:** Redirects to album show page
**Failure:** Re-renders new form with validation errors

**Note:** Artist associations handled separately (Phase 3)

#### `#edit`
Renders form for editing an existing album.

**View:** `app/views/admin/music/albums/edit.html.erb`

#### `#update`
Updates an existing album record.

**Parameters:** Same as #create

**Success:** Redirects to album show page
**Failure:** Re-renders edit form with validation errors

#### `#destroy`
Permanently deletes an album and its dependent records.

**Dependent Handling:**
- Releases, images, external links cascade via database constraints
- Warning about list items and rankings shown in UI before deletion

**Success:** Redirects to albums index

### Action Execution Methods

#### `#execute_action`
Executes single-record actions on an album.

**Parameters:**
- `action_name` (required) - Action class name (e.g., "MergeAlbum")
- Additional fields specific to each action

**Supported Actions:**
- `GenerateAlbumDescription` - Queues AI description job
- `MergeAlbum` - Merges duplicate album into this one

**Response Formats:**
- Turbo Stream: Updates flash message
- HTML: Redirects to album show page

#### `#bulk_action`
Executes actions on multiple albums.

**Parameters:**
- `action_name` (required) - Action class name
- `album_ids[]` (required) - Array of album IDs

**Supported Actions:**
- `GenerateAlbumDescription` - Queues AI description jobs for all selected albums

**Response Formats:**
- Turbo Stream: Updates flash and reloads table
- HTML: Redirects to albums index

#### `#search`
JSON endpoint for autocomplete/search functionality.

**Parameters:**
- `q` (required) - Search query

**Response:**
```json
[
  {
    "value": 123,
    "text": "Dark Side of the Moon - Pink Floyd"
  }
]
```

**Features:**
- Returns up to 10 results
- Filters to matched album IDs only (explicit `.where(id:)` for clarity)
- Includes artist names in result text
- Preserves OpenSearch relevance ranking
- Empty query returns empty array

## Private Methods

### `#set_album`
Before action callback that loads album from params[:id].

**Used By:** show, edit, update, destroy, execute_action

### `#load_albums_for_index`
Loads and filters albums for index page.

**Logic:**
- If `params[:q]` present: Uses OpenSearch, filters with `where(id:)`, preserves ranking with `in_order_of`
- Otherwise: Standard database query with sorting
- Always paginates at 25 items per page

**N+1 Prevention:** Eager loads categories and album_artists with artists

**Note on `in_order_of` behavior:** Rails 8+ automatically filters records to the specified IDs when using `in_order_of`, but we explicitly add `.where(id: album_ids)` for code clarity and defensive programming.

### `#sortable_column(column)`
Whitelists and maps sort parameters to table-qualified column names.

**Allowed Columns:**
- `id` → `music_albums.id`
- `title` → `music_albums.title`
- `release_year` → `music_albums.release_year`
- `created_at` → `music_albums.created_at`

**Default:** `music_albums.title`

**Security:** Prevents SQL injection via whitelist

### `#album_params`
Strong parameters for album attributes.

**Permitted Attributes:**
- `title` (string, required)
- `description` (text)
- `release_year` (integer)

## Authentication & Authorization

**Required Role:** Admin or Editor

**Inherited From:** Admin::Music::BaseController → Admin::BaseController

**Failure Behavior:** Redirects to root with alert message

## Routes

All routes under `/admin/albums` (inside music domain constraint):

```ruby
GET    /admin/albums                        # index
GET    /admin/albums/:id                    # show
GET    /admin/albums/new                    # new
POST   /admin/albums                        # create
GET    /admin/albums/:id/edit               # edit
PATCH  /admin/albums/:id                    # update
DELETE /admin/albums/:id                    # destroy
POST   /admin/albums/:id/execute_action     # execute_action
POST   /admin/albums/bulk_action            # bulk_action
GET    /admin/albums/search                 # search
```

## View Components

**Reused Components:**
- `Admin::SearchComponent` - Debounced search input with Turbo Frame integration

## Dependencies

**Services:**
- `Search::Music::Search::AlbumGeneral` - OpenSearch album search
- `Music::Album::Merger` - Album merge service
- `Music::AlbumDescriptionJob` - Background AI description job

**Gems:**
- `pagy` - Pagination

## Testing

**Test File:** `test/controllers/admin/music/albums_controller_test.rb`

**Coverage:**
- 26 controller tests
- 119 assertions
- 100% passing

**Test Categories:**
- Authentication/Authorization (4 tests)
- Index with search & sorting (7 tests)
- CRUD operations (7 tests)
- Search autocomplete (3 tests)
- Action execution (4 tests)
- Edge cases (1 test)

## Performance Optimizations

**N+1 Query Prevention:**
- Index: `.includes(:categories, album_artists: [:artist])`
- Show: Deep eager loading of 8+ associations

**Search Performance:**
- Fetches up to 1000 results from OpenSearch
- Uses `in_order_of` to preserve relevance ranking
- Paginated at 25 items per page

**Turbo Frame Optimization:**
- Table wrapped in `albums_table` frame for partial updates
- Search and sort don't trigger full page reload

## Common Gotchas

1. **Form URLs:** Must use explicit URLs (`admin_album_path` / `admin_albums_path`) due to double-namespace with Music::Album model
2. **Image Variants:** Check `image.file.attached?` before calling `variant()` methods
3. **Background Jobs:** Create action triggers `ImportAlbumReleasesJob` - stub in tests
4. **External Links:** Use `link.name` not `link.label` attribute

## Related Documentation

- [Admin::Music::ArtistsController](artists_controller.md) - Similar pattern reference
- [Actions::Admin::Music::MergeAlbum](../../lib/actions/admin/music/merge_album.md)
- [Actions::Admin::Music::GenerateAlbumDescription](../../lib/actions/admin/music/generate_album_description.md)
- [Phase 2 Implementation](../../todos/073-custom-admin-phase-2-albums.md)

## Implementation History

- **Created:** 2025-11-09 (Phase 2)
- **Pattern Source:** Admin::Music::ArtistsController (Phase 1)
- **Last Updated:** 2025-11-09

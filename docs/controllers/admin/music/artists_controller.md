# Admin::Music::ArtistsController

## Summary
Admin controller for managing `Music::Artist` records. Provides CRUD operations, search, bulk actions, and MusicBrainz import functionality.

**File**: `app/controllers/admin/music/artists_controller.rb`

## Dependencies
- `Admin::Music::BaseController` - Base admin controller with authentication
- `DataImporters::Music::Artist::Importer` - Artist import from MusicBrainz
- `Search::Music::Search::ArtistGeneral` - OpenSearch for index page search
- `Search::Music::Search::ArtistAutocomplete` - OpenSearch for autocomplete
- `Actions::Admin::Music::*` - Action classes for execute_action, bulk_action, index_action

## Actions

### Standard CRUD

#### `index`
Lists artists with pagination, search, and sorting.
- **Search**: Uses OpenSearch via `ArtistGeneral` when `params[:q]` present
- **Sorting**: Whitelist of allowed columns (id, name, kind, created_at)
- **Pagination**: 25 items per page via Pagy

#### `show`
Displays single artist with eager-loaded associations.
- Includes: categories, identifiers, primary_image, album_artists, song_artists, images

#### `new` / `create`
Standard resource creation.
- Permitted params: name, description, kind, born_on, year_died, year_formed, year_disbanded, country

#### `edit` / `update`
Standard resource update.

#### `destroy`
Deletes artist.

### Action Execution

#### `execute_action`
Executes single-record action classes on an artist.
- **Route**: `POST /admin/artists/:id/execute_action`
- **Params**: `action_name` (string), plus action-specific fields
- **Response**: Turbo Stream updating flash, or HTML redirect
- **Example actions**: `GenerateArtistDescription`, `RefreshArtistRanking`, `MergeArtist`

#### `bulk_action`
Executes action on multiple selected artists.
- **Route**: `POST /admin/artists/bulk_action`
- **Params**: `action_name`, `artist_ids[]`
- **Response**: Turbo Stream updating flash and table

#### `index_action`
Executes collection-level action (no specific models).
- **Route**: `POST /admin/artists/index_action`
- **Params**: `action_name`
- **Example actions**: `RefreshAllArtistsRankings`

### Search

#### `search`
JSON endpoint for autocomplete.
- **Route**: `GET /admin/artists/search`
- **Params**: `q` (query), `exclude_id` (optional, for merge modal)
- **Response**: `[{value: id, text: name}, ...]`

### Import

#### `import_from_musicbrainz`
Imports an artist from MusicBrainz by ID.
- **Route**: `POST /admin/artists/import_from_musicbrainz`
- **Params**: `musicbrainz_id` (MusicBrainz UUID)
- **Behavior**:
  - Validates `musicbrainz_id` presence
  - Calls `DataImporters::Music::Artist::Importer.call(musicbrainz_id: ...)`
  - If artist already exists (finder returns early): redirects to existing artist with "Artist already exists"
  - If new artist imported: redirects to new artist with "Artist imported successfully"
  - If import fails: redirects to index with error message
- **Added**: Spec 119

## Routes

```ruby
resources :artists do
  member do
    post :execute_action
  end
  collection do
    post :import_from_musicbrainz
    post :bulk_action
    post :index_action
    get :search
  end
end
```

## Views

- `index.html.erb` - Artist list with search, pagination, Import From MusicBrainz modal
- `show.html.erb` - Artist details with albums, songs, categories, modals for adding associations
- `new.html.erb` / `edit.html.erb` - Standard form
- `_table.html.erb` - Partial for artist table (used in turbo frame)
- `_albums_list.html.erb` - Partial for albums section
- `_songs_list.html.erb` - Partial for songs section

## Related Documentation
- `docs/features/data_importers.md` - Data importer architecture
- `docs/specs/completed/119-admin-import-artist-from-musicbrainz.md` - Import feature spec
- `docs/specs/completed/120-refactor-musicbrainz-search-controller.md` - MusicBrainz search endpoint

# Admin::Music::Songs::ListItemsActionsController

## Summary
Handles per-item actions for list items in the Song Wizard review step. Provides endpoints for verifying items, editing metadata, linking to existing songs, and searching/linking MusicBrainz recordings and artists.

## File Path
`app/controllers/admin/music/songs/list_items_actions_controller.rb`

## Parent Controller
`Admin::Music::BaseController` (requires admin authentication)

## Constants

### `VALID_MODAL_TYPES`
Array of valid modal types for the `modal` action:
- `edit_metadata` - Edit raw JSON metadata
- `link_song` - Link to existing song in database
- `search_musicbrainz_recordings` - Search and link MusicBrainz recordings
- `search_musicbrainz_artists` - Search and link MusicBrainz artists

## Actions

### `modal` (GET)
Loads modal content on-demand for the shared modal component.

**Route**: `GET /admin/songs/lists/:list_id/items/:id/modal/:modal_type`

**Parameters**:
- `modal_type` - One of `VALID_MODAL_TYPES`

**Behavior**:
- Validates `modal_type` against `VALID_MODAL_TYPES`
- Renders the appropriate partial from `modals/` subdirectory
- Returns content wrapped in `turbo_frame_tag` for Turbo Frame replacement

### `verify` (POST)
Marks a list item as verified.

**Route**: `POST /admin/songs/lists/:list_id/items/:id/verify`

**Behavior**:
- Sets `verified = true` on the item
- Clears `ai_match_invalid` from metadata (admin override)
- Returns Turbo Stream response updating the table row and stats

### `metadata` (PATCH)
Updates the raw JSON metadata of a list item.

**Route**: `PATCH /admin/songs/lists/:list_id/items/:id/metadata`

**Parameters**:
- `list_item[metadata_json]` - JSON string of the new metadata

**Behavior**:
- Parses and validates JSON
- Updates `list_item.metadata` with parsed data
- Returns error if JSON is invalid
- Returns Turbo Stream response updating the table row

### `manual_link` (POST)
Links a list item to an existing song in the database.

**Route**: `POST /admin/songs/lists/:list_id/items/:id/manual_link`

**Parameters**:
- `song_id` - ID of the `Music::Song` to link

**Behavior**:
- Sets `listable` to the selected song
- Sets `verified = true`
- Updates metadata with `song_id`, `song_name`, `manual_link` flags
- Returns Turbo Stream response updating the table row

### `link_musicbrainz_recording` (POST)
Links a list item to a MusicBrainz recording.

**Route**: `POST /admin/songs/lists/:list_id/items/:id/link_musicbrainz_recording`

**Parameters**:
- `mb_recording_id` - MusicBrainz recording UUID

**Behavior**:
1. Looks up recording details via `Music::Musicbrainz::Search::RecordingSearch#lookup_by_mbid`
2. Updates metadata with MB data (`mb_recording_id`, `mb_recording_name`, `mb_artist_names`, `mb_release_year`, etc.)
3. Sets `verified = true` (MusicBrainz match is authoritative)
4. If a `Music::Song` exists with this recording ID, sets `listable` to that song
5. If no matching song exists, clears any stale `listable` reference
6. Returns Turbo Stream response updating the table row

### `link_musicbrainz_artist` (POST)
Links a MusicBrainz artist to a list item, replacing existing artist metadata.

**Route**: `POST /admin/songs/lists/:list_id/items/:id/link_musicbrainz_artist`

**Parameters**:
- `mb_artist_id` - MusicBrainz artist UUID

**Behavior**:
1. Looks up artist details via `Music::Musicbrainz::Search::ArtistSearch#lookup_by_mbid`
2. Replaces `mb_artist_ids` with single-element array containing selected artist MBID
3. Replaces `mb_artist_names` with single-element array containing artist name
4. Returns Turbo Stream response updating the table row

**Use Case**: Allows manual correction of artist match when the enrich step matched the wrong artist.

### `musicbrainz_recording_search` (GET)
Autocomplete endpoint for searching MusicBrainz recordings.

**Route**: `GET /admin/songs/lists/:list_id/wizard/musicbrainz_recording_search`

**Parameters**:
- `item_id` - ID of the list item (required)
- `q` - Search query (min 2 characters)

**Behavior**:
- Requires `item_id` - looks up the item to get artist MBID from metadata
- Only works if item has `mb_artist_ids` in metadata (returns empty array otherwise)
- Uses `RecordingSearch#search_by_artist_mbid_and_title` for precise results within the artist's catalog
- Returns JSON array: `[{value: "mbid", text: "Title - Artists (Year)"}]`

**Design Note**: Free-form MusicBrainz search returns too many irrelevant results. Requiring an artist MBID (from the enrich step) enables much more precise searching.

### `musicbrainz_artist_search` (GET)
Autocomplete endpoint for searching MusicBrainz artists.

**Route**: `GET /admin/songs/lists/:list_id/wizard/musicbrainz_artist_search`

**Parameters**:
- `q` - Search query (min 2 characters)

**Behavior**:
- Searches MusicBrainz for artists by name
- Uses `ArtistSearch#search_by_name` with limit of 10 results
- Returns JSON array: `[{value: "mbid", text: "Artist Name (Type from Location)"}]`

**Display Format**: Artists are formatted as "Artist Name (Type from Location)" where:
- Type: "Person", "Group", etc.
- Location: disambiguation field or country code

## Private Methods

### `set_list`
Finds the `Music::Songs::List` from `params[:list_id]`.

### `set_item`
Finds the list item from `@list.list_items` using `params[:id]`.

### `review_step_path`
Returns the path to the review step for redirects.

### `extract_artist_names_from_recording(recording)`
Extracts artist names from MusicBrainz recording data.

### `extract_year_from_recording(recording)`
Extracts release year from MusicBrainz recording data.

### `format_artist_display(artist)`
Formats artist for autocomplete display as "Artist Name (Type from Location)".

## Dependencies
- `Music::Musicbrainz::Search::RecordingSearch` - For MusicBrainz recording API queries
- `Music::Musicbrainz::Search::ArtistSearch` - For MusicBrainz artist API queries
- `Music::Songs::List` - The list model
- `ListItem` - The list item model

## Modal Partials

Located in `app/views/admin/music/songs/list_items_actions/modals/`:

| Partial | Purpose |
|---------|---------|
| `_edit_metadata.html.erb` | JSON metadata editor |
| `_link_song.html.erb` | Link to existing song autocomplete |
| `_search_musicbrainz_recordings.html.erb` | MusicBrainz recording search |
| `_search_musicbrainz_artists.html.erb` | MusicBrainz artist search |
| `_error.html.erb` | Error display for invalid modal types |

## Related Files
- `app/components/admin/music/songs/wizard/review_step_component.rb` - Renders the review UI
- `app/components/admin/music/songs/wizard/shared_modal_component.rb` - Shared modal dialog
- `app/views/admin/music/songs/list_items_actions/_item_row.html.erb` - Row partial for Turbo updates
- `app/views/admin/music/songs/list_items_actions/_review_stats.html.erb` - Stats partial for Turbo updates

## Test File
`test/controllers/admin/music/songs/list_items_actions_controller_test.rb`

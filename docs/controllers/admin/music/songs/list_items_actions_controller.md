# Admin::Music::Songs::ListItemsActionsController

## Summary
Handles per-item actions for list items in the Song Wizard review step. Provides endpoints for verifying items, editing metadata, linking to existing songs, and searching/linking MusicBrainz recordings.

## File Path
`app/controllers/admin/music/songs/list_items_actions_controller.rb`

## Parent Controller
`Admin::Music::BaseController` (requires admin authentication)

## Actions

### `verify` (POST)
Marks a list item as verified.

**Route**: `POST /admin/songs/lists/:list_id/items/:id/verify`

**Behavior**:
- Sets `verified = true` on the item
- Returns Turbo Stream response updating the table row

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

### `link_musicbrainz` (POST)
Links a list item to a MusicBrainz recording.

**Route**: `POST /admin/songs/lists/:list_id/items/:id/link_musicbrainz`

**Parameters**:
- `mb_recording_id` - MusicBrainz recording UUID

**Behavior**:
1. Looks up recording details via `Music::Musicbrainz::Search::RecordingSearch#lookup_by_mbid`
2. Updates metadata with MB data (`mb_recording_id`, `mb_recording_name`, `mb_artist_names`, `mb_release_year`, etc.)
3. Sets `verified = true` (MusicBrainz match is authoritative)
4. If a `Music::Song` exists with this recording ID, also sets `listable` to that song
5. Returns Turbo Stream response updating the table row

### `musicbrainz_search` (GET)
Autocomplete endpoint for searching MusicBrainz recordings.

**Route**: `GET /admin/songs/lists/:list_id/wizard/musicbrainz_search`

**Parameters**:
- `item_id` - ID of the list item (required)
- `q` - Search query (min 2 characters)

**Behavior**:
- Requires `item_id` - looks up the item to get artist MBID from metadata
- Only works if item has `mb_artist_ids` in metadata (returns empty array otherwise)
- Uses `RecordingSearch#search_by_artist_mbid_and_title` for precise results within the artist's catalog
- Returns JSON array: `[{value: "mbid", text: "Title - Artists (Year)"}]`

**Design Note**: Free-form MusicBrainz search returns too many irrelevant results. Requiring an artist MBID (from the enrich step) enables much more precise searching.

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

## Dependencies
- `Music::Musicbrainz::Search::RecordingSearch` - For MusicBrainz API queries
- `Music::Songs::List` - The list model
- `ListItem` - The list item model

## Related Files
- `app/components/admin/music/songs/wizard/review_step_component.rb` - Renders the review UI
- `app/components/admin/music/songs/wizard/edit_metadata_modal_component.rb` - Metadata editing modal
- `app/components/admin/music/songs/wizard/link_song_modal_component.rb` - Link existing song modal
- `app/components/admin/music/songs/wizard/search_musicbrainz_modal_component.rb` - MusicBrainz search modal
- `app/views/admin/music/songs/list_items_actions/_item_row.html.erb` - Row partial for Turbo updates

## Test File
`test/controllers/admin/music/songs/list_items_actions_controller_test.rb`

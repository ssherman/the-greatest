# Admin::Music::Albums::ListItemsActionsController

## Summary
Handles per-item actions for the Albums List Wizard review step. Provides endpoints for verifying items, editing metadata, linking to existing albums, and searching MusicBrainz for release groups and artists.

## Inheritance
Inherits from `Admin::Music::BaseController`.

## Before Actions
- `set_list` - Loads the parent `Music::Albums::List`
- `set_item` - Loads the specific `ListItem` (except for search endpoints)

## Constants

### VALID_MODAL_TYPES
Array of allowed modal types for the `modal` action:
- `edit_metadata` - JSON metadata editor
- `link_album` - Link to existing album
- `search_musicbrainz_releases` - Search MusicBrainz release groups
- `search_musicbrainz_artists` - Search MusicBrainz artists

## Public Methods

### modal
Loads modal content on-demand for the shared modal component.
- **Route**: `GET /admin/albums/:list_id/items/:id/modal/:modal_type`
- **Parameters**: `modal_type` (String) - One of VALID_MODAL_TYPES
- **Returns**: Rendered partial wrapped in turbo-frame

### verify
Marks an item as verified and clears `ai_match_invalid` flag.
- **Route**: `POST /admin/albums/:list_id/items/:id/verify`
- **Returns**: Turbo Stream (replace row, update stats, flash) or redirect

### skip
Marks an item as skipped.
- **Route**: `POST /admin/albums/:list_id/items/:id/skip`
- **Returns**: Turbo Stream or redirect

### metadata
Updates item metadata from JSON input.
- **Route**: `PATCH /admin/albums/:list_id/items/:id/metadata`
- **Parameters**: `list_item[metadata_json]` (String) - JSON string
- **Returns**: Turbo Stream or redirect; error if invalid JSON

### manual_link
Links item to an existing `Music::Album` by ID.
- **Route**: `POST /admin/albums/:list_id/items/:id/manual_link`
- **Parameters**: `album_id` (Integer) - Album ID to link
- **Side Effects**: Sets `listable`, marks verified, updates metadata with `album_id`, `album_name`, `manual_link`

### link_musicbrainz_release
Links item to a MusicBrainz release group by MBID.
- **Route**: `POST /admin/albums/:list_id/items/:id/link_musicbrainz_release`
- **Parameters**: `mb_release_group_id` (String) - MusicBrainz release group UUID
- **Side Effects**:
  - Looks up release group via `ReleaseGroupSearch.lookup_by_release_group_mbid`
  - Updates metadata with `mb_release_group_id`, `mb_release_group_name`, `mb_artist_names`, `mb_release_year`
  - If local album exists with matching MBID, links to it; otherwise clears listable

### link_musicbrainz_artist
Changes the artist match for an item.
- **Route**: `POST /admin/albums/:list_id/items/:id/link_musicbrainz_artist`
- **Parameters**: `mb_artist_id` (String) - MusicBrainz artist UUID
- **Side Effects**:
  - Clears stale release group data (`mb_release_group_id`, etc.)
  - Clears stale album link
  - Sets `mb_artist_ids`, `mb_artist_names`
  - Marks item as unverified

### re_enrich
Clears enrichment data for re-processing.
- **Route**: `POST /admin/albums/:list_id/items/:id/re_enrich`
- **Side Effects**: Clears all MusicBrainz and OpenSearch metadata

### queue_import
Marks item for import.
- **Route**: `POST /admin/albums/:list_id/items/:id/queue_import`
- **Side Effects**: Sets `queued_for_import` in metadata

### musicbrainz_release_search
JSON endpoint for MusicBrainz release group autocomplete.
- **Route**: `GET /admin/albums/:list_id/wizard/musicbrainz_release_search`
- **Parameters**:
  - `item_id` (Integer) - Item to search for
  - `q` (String) - Search query (min 2 chars)
- **Returns**: JSON array of `{value: mbid, text: "Title - Artist (Year) [Type]"}`
- **Notes**: Searches within the artist's catalog using `mb_artist_ids` from item metadata

### musicbrainz_artist_search
JSON endpoint for MusicBrainz artist autocomplete.
- **Route**: `GET /admin/albums/:list_id/wizard/musicbrainz_artist_search`
- **Parameters**: `q` (String) - Search query (min 2 chars)
- **Returns**: JSON array of `{value: mbid, text: "Artist Name (Type from Location)"}`

### bulk_verify
Verifies multiple items at once.
- **Route**: `POST /admin/albums/:list_id/items/bulk_verify`
- **Parameters**: `item_ids` (Array) - IDs to verify

### bulk_skip
Skips multiple items at once.
- **Route**: `POST /admin/albums/:list_id/items/bulk_skip`
- **Parameters**: `item_ids` (Array) - IDs to skip

### bulk_delete
Deletes multiple items.
- **Route**: `DELETE /admin/albums/:list_id/items/bulk_delete`
- **Parameters**: `item_ids` (Array) - IDs to delete

## Turbo Stream Response Pattern

All item modification actions return an array of three turbo streams:
```ruby
render turbo_stream: [
  turbo_stream.replace("item_row_#{@item.id}", partial: "item_row", locals: {item: @item}),
  turbo_stream.replace("review_stats_#{@list.id}", partial: "review_stats", locals: {list: @list}),
  turbo_stream.append("flash_messages", partial: "flash_success", locals: {message: "..."})
]
```

## Dependencies
- `Music::Musicbrainz::Search::ReleaseGroupSearch` - For release group lookups
- `Music::Musicbrainz::Search::ArtistSearch` - For artist lookups
- `Admin::Music::Albums::Wizard::SharedModalComponent` - For modal error IDs

## Related Files
- View partials: `app/views/admin/music/albums/list_items_actions/`
- Modal partials: `app/views/admin/music/albums/list_items_actions/modals/`
- Helper: `app/helpers/admin/music/albums/list_items_actions_helper.rb`
- Component: `app/components/admin/music/albums/wizard/review_step_component.rb`

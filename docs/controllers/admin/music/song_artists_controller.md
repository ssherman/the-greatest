# Admin::Music::SongArtistsController

## Summary
Manages CRUD operations for the Music::SongArtist join table, allowing admin and editor users to associate artists with songs through a context-aware interface. Supports operations from both song show pages (adding artists to a song) and artist show pages (adding songs to an artist).

## Location
`app/controllers/admin/music/song_artists_controller.rb`

## Inheritance
Inherits from `Admin::Music::BaseController`, which provides:
- Admin/editor role authorization
- Music domain enforcement
- Standard admin layout

## Controller Actions

### `create`
Creates a new song-artist association.
- **Parameters**: `music_song_artist[song_id, artist_id, position]`
- **Context**: Determined by parent route (song or artist)
- **Responses**:
  - Success: Turbo Stream updates + flash notice
  - Failure: Turbo Stream error flash (422 status)
- **Authorization**: Admin or editor role required

### `update`
Updates the position of an existing song-artist association.
- **Parameters**: `music_song_artist[position]`
- **Context**: Inferred from referer URL
- **Responses**:
  - Success: Turbo Stream updates + flash notice
  - Failure: Turbo Stream error flash (422 status)
- **Authorization**: Admin or editor role required

### `destroy`
Removes a song-artist association.
- **Parameters**: None (ID in route)
- **Context**: Inferred from referer URL
- **Responses**: Turbo Stream updates + flash notice
- **Authorization**: Admin or editor role required

## Context Detection

The controller operates in two contexts:

### Song Context (`:song`)
- Triggered by: `song_id` param present or referer contains `/admin/songs/`
- Redirect path: `admin_song_path(@song_artist.song)`
- Turbo frame: `"song_artists_list"`
- Partial: `"admin/music/songs/artists_list"`

### Artist Context (`:artist`)
- Triggered by: `artist_id` param present or referer contains `/admin/artists/`
- Redirect path: `admin_artist_path(@song_artist.artist)`
- Turbo frame: `"artist_songs_list"`
- Partial: `"admin/music/artists/songs_list"`

## Routes

| Verb | Path | Action | Context |
|------|------|--------|---------|
| POST | `/admin/songs/:song_id/song_artists` | create | Song |
| POST | `/admin/artists/:artist_id/song_artists` | create | Artist |
| PATCH | `/admin/song_artists/:id` | update | Inferred |
| DELETE | `/admin/song_artists/:id` | destroy | Inferred |

## Private Methods

### `set_song_artist`
Finds the SongArtist record by ID for update/destroy actions.

### `set_parent_context`
Determines context (song or artist) from parent route parameters for create action.

### `infer_context_from_song_artist`
Infers context from the referer URL for update/destroy actions when no parent param is present.

### `song_artist_params`
Strong parameters whitelist: `[:song_id, :artist_id, :position]`

### `redirect_path`
Returns appropriate redirect path based on context.

### `turbo_frame_id`
Returns appropriate Turbo Frame ID based on context.

### `partial_path`
Returns appropriate partial path based on context.

### `partial_locals`
Returns appropriate locals hash for partial rendering based on context.

## Response Patterns

### Success Response
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: {flash: {notice: "Artist added successfully."}})
turbo_stream.replace(turbo_frame_id,
  partial: partial_path,
  locals: partial_locals)
```

### Error Response
```ruby
turbo_stream.replace("flash",
  partial: "admin/shared/flash",
  locals: {flash: {error: @song_artist.errors.full_messages.join(", ")}})
# Status: 422 Unprocessable Entity
```

## Validations Enforced
- Uniqueness of song-artist pair (model validation)
- Position must be integer > 0 (model validation)
- Both song_id and artist_id must be present (model validation)

## Dependencies
- `Music::SongArtist` model
- `Music::Song` model
- `Music::Artist` model
- Turbo Streams for real-time updates
- Modal-form Stimulus controller for auto-closing modals
- AutocompleteComponent for artist/song search

## Related Files
- **Views**:
  - `app/views/admin/music/songs/_artists_list.html.erb`
  - `app/views/admin/music/artists/_songs_list.html.erb`
- **Model**: `app/models/music/song_artist.rb`
- **Tests**: `test/controllers/admin/music/song_artists_controller_test.rb`
- **Pattern Source**: `app/controllers/admin/music/album_artists_controller.rb`

## Testing
Comprehensive test suite with 15 tests covering:
- CRUD operations from both contexts
- Authorization enforcement
- Context detection and inference
- Duplicate prevention
- Validation handling
- Turbo Stream responses

See: `test/controllers/admin/music/song_artists_controller_test.rb`

## Implementation Notes
This controller follows the exact same pattern as `AlbumArtistsController`, adapted for songs instead of albums. The dual-context pattern allows the same controller actions to work seamlessly from both parent resources (songs and artists).

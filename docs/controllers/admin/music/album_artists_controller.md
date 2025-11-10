# Admin::Music::AlbumArtistsController

## Summary
Manages CRUD operations for Music::AlbumArtist join table associations. Handles adding, editing positions, and removing artist associations from both album and artist admin pages. Context-aware controller that determines parent resource from URL parameters or referer.

## Actions

### `#create`
Creates a new album-artist association.
- Parameters: `music_album_artist[album_id]`, `music_album_artist[artist_id]`, `music_album_artist[position]`
- Context determined by: `album_id` or `artist_id` param
- Success: Redirects to parent resource (album or artist show page)
- Turbo Stream: Replaces flash and updates album_artists_list or artist_albums_list frame
- Validations: Prevents duplicate album-artist pairs

### `#update`
Updates the position of an existing album-artist association.
- Parameters: `music_album_artist[position]`
- Context determined by: Referer URL
- Success: Redirects to parent resource
- Turbo Stream: Replaces flash and updates appropriate list frame

### `#destroy`
Removes an album-artist association.
- Context determined by: Referer URL
- Success: Redirects to parent resource
- Turbo Stream: Replaces flash and updates appropriate list frame

## Context Detection

The controller uses two strategies to determine context (album vs artist page):

1. **Create action**: Checks `params[:album_id]` or `params[:artist_id]`
2. **Update/Destroy actions**: Checks `request.referer` for `/admin/artists/` or `/admin/albums/`

Context determines:
- Which turbo frame to replace (`album_artists_list` or `artist_albums_list`)
- Which partial to render (`artists_list` or `albums_list`)
- Redirect path after operation

## Authorization
- Requires admin or editor role
- Enforced by `Admin::Music::BaseController`

## Routes
```ruby
# Nested create routes (not shallow)
POST /admin/albums/:album_id/album_artists
POST /admin/artists/:artist_id/album_artists

# Shallow routes for update/destroy
PATCH /admin/album_artists/:id
DELETE /admin/album_artists/:id
```

## Dependencies
- `Music::AlbumArtist` model
- `Music::Album` model
- `Music::Artist` model
- Turbo Streams for dynamic updates
- Referer header for context detection

# Music::SongArtist

## Summary
Join table model for many-to-many relationships between songs and artists. Enables songs to have multiple artists independent of their album artists, supporting guest features, covers, and compilation albums.

## Associations
- `belongs_to :song, class_name: "Music::Song"` - The song
- `belongs_to :artist, class_name: "Music::Artist"` - The artist

## Public Methods
This model primarily serves as a join table and doesn't have custom public methods beyond ActiveRecord associations.

## Validations
- `song` - presence required
- `artist` - presence required
- `position` - presence required, must be positive integer  
- `artist_id` - uniqueness per song (prevents duplicate artist associations)

## Scopes
- `ordered` - Orders by position for consistent artist ordering

## Constants
- Default `position` value: 1

## Dependencies
- Music::Song - Parent song model
- Music::Artist - Associated artist model

## Usage Examples

```ruby
# Create song with guest feature
song = Music::Song.create!(title: "Empire State of Mind")
song.song_artists.create!(artist: jay_z, position: 1)
song.song_artists.create!(artist: alicia_keys, position: 2)

# Access ordered artists  
song.artists.ordered # Returns artists in position order

# Song can have different artists than its album
album = jay_z.albums.find_by(title: "The Blueprint 3")
album.artists # [Jay-Z]
song.artists  # [Jay-Z, Alicia Keys]
```

## Database Schema
- `song_id` (bigint, not null, foreign key)
- `artist_id` (bigint, not null, foreign key) 
- `position` (integer, default: 1)
- Standard timestamps

## Indexes
- `(song_id, artist_id)` - Unique constraint
- `(song_id, position)` - Position ordering
- `song_id` - Foreign key index
- `artist_id` - Foreign key index
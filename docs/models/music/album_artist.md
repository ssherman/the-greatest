# Music::AlbumArtist

## Summary
Join table model for many-to-many relationships between albums and artists. Enables albums to have multiple collaborating artists with position-based ordering.

## Associations
- `belongs_to :album, class_name: "Music::Album"` - The album
- `belongs_to :artist, class_name: "Music::Artist"` - The artist

## Public Methods
This model primarily serves as a join table and doesn't have custom public methods beyond ActiveRecord associations.

## Validations
- `album` - presence required
- `artist` - presence required  
- `position` - presence required, must be positive integer
- `artist_id` - uniqueness per album (prevents duplicate artist associations)

## Scopes
- `ordered` - Orders by position for consistent artist ordering

## Constants
- Default `position` value: 1

## Dependencies
- Music::Album - Parent album model
- Music::Artist - Associated artist model

## Usage Examples

```ruby
# Create album with multiple artists
album = Music::Album.create!(title: "Watch the Throne")
album.album_artists.create!(artist: jay_z, position: 1)
album.album_artists.create!(artist: kanye_west, position: 2)

# Access ordered artists
album.artists.ordered # Returns artists in position order

# Check if specific artist is associated
album.artists.include?(jay_z) # true
```

## Database Schema
- `album_id` (bigint, not null, foreign key)
- `artist_id` (bigint, not null, foreign key)
- `position` (integer, default: 1)
- Standard timestamps

## Indexes
- `(album_id, artist_id)` - Unique constraint
- `(album_id, position)` - Position ordering
- `album_id` - Foreign key index
- `artist_id` - Foreign key index
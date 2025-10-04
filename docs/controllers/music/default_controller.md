# Music::DefaultController

## Summary
Handles the Music domain homepage. Displays featured albums and songs from the primary ranking configurations.

## Inheritance
- `ApplicationController` - Base Rails controller

## Responsibilities
- Display music domain homepage/landing page
- Load and display featured albums from primary album ranking
- Load and display featured songs from primary song ranking
- Gracefully handle missing ranking configurations

## Public Methods

### `#index`
Displays the music homepage with featured content
- **URL**: `/music` (root of music domain)
- **Parameters**: None
- **Sets instance variables**:
  - `@primary_album_rc` - Default primary album RankingConfiguration
  - `@primary_song_rc` - Default primary song RankingConfiguration
  - `@featured_albums` - Top 6 ranked albums (if album ranking exists)
  - `@featured_songs` - Top 10 ranked songs (if song ranking exists)
- **Eager loads**:
  - Albums: item (albums) with artists and primary_image
  - Songs: item (songs) with artists

## Layout
Uses `music/application` layout for consistent music domain styling

## Query Patterns

### Featured Albums Query
- Loads top 6 ranked albums from primary ranking configuration
- Joins through ranked_items association
- Filters by item_type 'Music::Album'
- Orders by rank ASC (best albums first)
- Includes associations for display (artists, images)
- Only executes if primary album ranking configuration exists

### Featured Songs Query
- Loads top 10 ranked songs from primary ranking configuration
- Joins through ranked_items association
- Filters by item_type 'Music::Song'
- Orders by rank ASC (best songs first)
- Includes associations for display (artists)
- Only executes if primary song ranking configuration exists

## Dependencies
- `Music::Albums::RankingConfiguration` - Album ranking configuration model
- `Music::Songs::RankingConfiguration` - Song ranking configuration model
- `RankedItem` - Individual ranking records
- `Music::Album` - Album model
- `Music::Song` - Song model
- `Music::Artist` - Artist model

## Routing
Serves as root path for `/music` namespace

## Related Documentation
- Task: `/home/shane/dev/the-greatest/docs/todos/045-greatest-songs-ui-and-album-improvements.md`
- Album Model: `/home/shane/dev/the-greatest/docs/models/music/album.md`
- Song Model: `/home/shane/dev/the-greatest/docs/models/music/song.md`
- Album RC: `/home/shane/dev/the-greatest/docs/models/music/albums/ranking_configuration.md`
- Song RC: `/home/shane/dev/the-greatest/docs/models/music/songs/ranking_configuration.md`

## Design Notes
- Updated to display both albums and songs (previously may have been albums-only)
- Gracefully handles nil ranking configurations with conditional loading
- Different display counts: 6 albums (visual/card layout) vs 10 songs (list layout)
- Uses default_primary method to find the main ranking configuration for each type
- Featured content provides entry point to full ranked lists and detail pages
- Serves as domain landing page with curated "best of" content

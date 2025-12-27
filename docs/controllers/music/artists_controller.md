# Music::ArtistsController

## Summary
Handles artist detail page display for the Music domain. Renders artist information with their greatest albums, greatest songs, and complete discography.

## Inheritance
- `ApplicationController` - Base Rails controller

## Responsibilities
- Display artist detail page with all metadata
- Show ranked lists of artist's greatest albums and songs
- Display complete album discography ordered chronologically
- Group and display artist categories by type

## Public Methods

### `#show`
Displays detailed information for a single artist including ranked albums and songs
- **URL**: `/music/artists/:id`
- **Parameters**:
  - `id` (String) - Artist slug or ID (via FriendlyId)
  - `ranking_configuration_id` (Integer, optional) - Specific album ranking configuration to display
- **Sets instance variables**:
  - `@artist` - The Music::Artist record with preloaded associations
  - `@categories_by_type` - Hash grouping categories by category_type
  - `@album_rc` - RankingConfiguration for album rankings
  - `@greatest_albums` - Top 10 ranked albums by this artist (ActiveRecord::Relation)
  - `@song_rc` - RankingConfiguration for song rankings
  - `@greatest_songs` - Top 10 ranked songs by this artist (ActiveRecord::Relation)
  - `@all_albums` - Complete discography ordered by release_year DESC
- **Eager loads**: categories, primary_image, artists (for albums), artists (for songs)

## Layout
Uses `music/application` layout for consistent music domain styling

## Query Patterns

### Greatest Albums Query
- Joins albums to ranked_items table
- Filters by item_type 'Music::Album' and ranking_configuration_id
- Orders by rank ASC
- Limits to top 10 results
- Returns empty array if no ranking configuration available

### Greatest Songs Query
- Joins songs to ranked_items table
- Filters by item_type 'Music::Song' and ranking_configuration_id
- Orders by rank ASC
- Limits to top 10 results
- Returns empty array if no ranking configuration available

### All Albums Query
- Loads complete discography
- Orders by release_year DESC (most recent first)
- Includes artists and primary_image for display

## Dependencies
- `Music::Artist` - Artist model with FriendlyId support
- `Music::Album` - Album model
- `Music::Song` - Song model
- `RankingConfiguration` - Base ranking configuration model
- `Music::Albums::RankingConfiguration` - Album-specific ranking configuration
- `Music::Songs::RankingConfiguration` - Song-specific ranking configuration
- `RankedItem` - Individual ranking records

## Routing
Namespaced under `/music` routes

## Related Documentation
- Spec: `/home/shane/dev/the-greatest/docs/specs/045-greatest-songs-ui-and-album-improvements.md`
- Model: `/home/shane/dev/the-greatest/docs/models/music/artist.md`
- Album Model: `/home/shane/dev/the-greatest/docs/models/music/album.md`
- Song Model: `/home/shane/dev/the-greatest/docs/models/music/song.md`

## Design Notes
- Uses default primary ranking configurations for both albums and songs
- Album ranking configuration can be overridden via params, song configuration uses default only
- Gracefully handles missing ranking configurations with empty arrays
- Manual SQL joins used for ranked items to maintain performance with proper indexes
- Categories grouped by type for flexible display (genre, origin, etc.)
- Discography shows all albums regardless of ranking status

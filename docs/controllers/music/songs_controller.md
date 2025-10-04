# Music::SongsController

## Summary
Handles song detail page display for the Music domain. Renders song information with rankings, categories, artists, and associated albums.

## Inheritance
- `ApplicationController` - Base Rails controller

## Responsibilities
- Display song detail page with all metadata
- Load and display song rankings from RankingConfiguration
- Group and display categories by type (genre, mood, etc.)
- Format artist information for display
- Display all albums containing the song

## Public Methods

### `#show`
Displays detailed information for a single song
- **URL**: `/music/songs/:id`
- **Parameters**:
  - `id` (String) - Song slug or ID (via FriendlyId)
  - `ranking_configuration_id` (Integer, optional) - Specific ranking configuration to display
- **Sets instance variables**:
  - `@song` - The Music::Song record with preloaded associations
  - `@categories_by_type` - Hash grouping categories by category_type
  - `@artist_names` - Comma-separated string of artist names
  - `@ranking_configuration` - RankingConfiguration to use for rankings
  - `@ranked_item` - RankedItem for this song in the selected configuration
  - `@albums` - All albums containing this song, ordered by release_year DESC
- **Eager loads**: artists, categories, albums (with artists and primary_image)

## Layout
Uses `music/application` layout for consistent music domain styling

## Dependencies
- `Music::Song` - Song model with FriendlyId support
- `Music::Album` - Album model (for associated albums)
- `RankingConfiguration` - Base ranking configuration model
- `Music::Songs::RankingConfiguration` - Song-specific ranking configuration
- `RankedItem` - Individual ranking records

## Routing
Namespaced under `/music` routes

## Related Documentation
- Task: `/home/shane/dev/the-greatest/docs/todos/045-greatest-songs-ui-and-album-improvements.md`
- Model: `/home/shane/dev/the-greatest/docs/models/music/song.md`
- Ranking Configuration: `/home/shane/dev/the-greatest/docs/models/music/songs/ranking_configuration.md`
- Album Model: `/home/shane/dev/the-greatest/docs/models/music/album.md`

## Design Notes
- Uses default primary ranking configuration if none specified in params
- Categories are grouped by type for flexible display
- Artist names are pre-formatted to avoid view logic
- Albums are displayed chronologically (newest first) using distinct to avoid duplicates
- Songs can appear on multiple albums (compilation albums, re-releases, etc.)

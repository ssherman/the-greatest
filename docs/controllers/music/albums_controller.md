# Music::AlbumsController

## Summary
Handles album detail page display for the Music domain. Renders album information with rankings, categories, and associated artists.

## Inheritance
- `ApplicationController` - Base Rails controller

## Responsibilities
- Display album detail page with all metadata
- Load and display album rankings from RankingConfiguration
- Group and display categories by type (genre, style, etc.)
- Format artist information for display

## Public Methods

### `#show`
Displays detailed information for a single album
- **URL**: `/music/albums/:id`
- **Parameters**:
  - `id` (String) - Album slug or ID (via FriendlyId)
  - `ranking_configuration_id` (Integer, optional) - Specific ranking configuration to display
- **Sets instance variables**:
  - `@album` - The Music::Album record with preloaded associations
  - `@categories_by_type` - Hash grouping categories by category_type
  - `@artist_names` - Comma-separated string of artist names
  - `@genre_text` - Primary genre name or "music" fallback
  - `@ranking_configuration` - RankingConfiguration to use for rankings
  - `@ranked_item` - RankedItem for this album in the selected configuration
- **Eager loads**: artists, categories, primary_image, lists

## Layout
Uses `music/application` layout for consistent music domain styling

## Dependencies
- `Music::Album` - Album model with FriendlyId support
- `RankingConfiguration` - Base ranking configuration model
- `Music::Albums::RankingConfiguration` - Album-specific ranking configuration
- `RankedItem` - Individual ranking records

## Routing
Namespaced under `/music` routes

## Related Documentation
- Spec: `/home/shane/dev/the-greatest/docs/specs/045-greatest-songs-ui-and-album-improvements.md`
- Model: `/home/shane/dev/the-greatest/docs/models/music/album.md`
- Ranking Configuration: `/home/shane/dev/the-greatest/docs/models/music/albums/ranking_configuration.md`

## Design Notes
- Uses default primary ranking configuration if none specified in params
- Categories are grouped by type for flexible display (genre, style, mood, etc.)
- Artist names are pre-formatted to avoid view logic
- Genre text extracted for meta/SEO purposes with fallback

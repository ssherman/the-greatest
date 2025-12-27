# Music::Songs::RankedItemsController

## Summary
Handles paginated display of ranked songs list for the Music domain. Shows songs ordered by their rank within a specific RankingConfiguration.

## Inheritance
- `Music::RankedItemsController` - Music domain base ranked items controller
  - `RankedItemsController` - Application-wide base ranked items controller
    - `ApplicationController` - Base Rails controller

## Responsibilities
- Display paginated list of all ranked songs
- Load ranking configuration (from params or default primary)
- Validate ranking configuration is correct type
- Order songs by rank
- Paginate results for performance

## Public Methods

### `self.ranking_configuration_class`
Returns the expected RankingConfiguration class for songs
- **Returns**: `Music::Songs::RankingConfiguration`
- **Purpose**: Used by parent controller for type validation and default loading

### `#index`
Displays paginated list of ranked songs
- **URL**: `/music/songs/ranked_items` or `/music/songs/ranking_configurations/:ranking_configuration_id/ranked_items`
- **Parameters**:
  - `ranking_configuration_id` (Integer, optional) - Specific ranking configuration to display
  - `page` (Integer, optional) - Page number for pagination
- **Sets instance variables**:
  - `@ranking_configuration` - The RankingConfiguration being displayed (set by before_action)
  - `@pagy` - Pagination metadata object
  - `@songs` - Paginated RankedItem records with preloaded song data
- **Eager loads**: item (songs) with their artists and categories
- **Pagination**: 100 songs per page

## Layout
Uses `music/application` layout for consistent music domain styling

## Before Actions
- `find_ranking_configuration` (from RankedItemsController)
  - Loads ranking configuration from params or default primary
  - Sets `@ranking_configuration` instance variable
  - Raises `ActiveRecord::RecordNotFound` if not found
- `validate_ranking_configuration_type` (from RankedItemsController)
  - Validates configuration is `Music::Songs::RankingConfiguration` type
  - Raises `ActiveRecord::RecordNotFound` if wrong type

## Query Pattern
```ruby
@ranking_configuration.ranked_items
  .joins("JOIN music_songs ON ranked_items.item_id = music_songs.id AND ranked_items.item_type = 'Music::Song'")
  .includes(item: [:artists, :categories])
  .where(item_type: "Music::Song")
  .order(:rank)
```

## Dependencies
- `Music::Songs::RankingConfiguration` - Song ranking configuration model
- `RankedItem` - Individual ranking records
- `Music::Song` - Song model
- `Music::Artist` - Artist model (through song)
- `Category` - Category model (through song)
- `Pagy::Backend` - Pagination gem

## Routing
Nested under `/music/songs` routes

## Related Documentation
- Parent Controller: `/home/shane/dev/the-greatest/docs/controllers/music/ranked_items_controller.md`
- Base Controller: `/home/shane/dev/the-greatest/docs/controllers/ranked_items_controller.md`
- Spec: `/home/shane/dev/the-greatest/docs/specs/045-greatest-songs-ui-and-album-improvements.md`
- Model: `/home/shane/dev/the-greatest/docs/models/music/songs/ranking_configuration.md`
- RankedItem Model: `/home/shane/dev/the-greatest/docs/models/ranked_item.md`

## Design Notes
- Uses manual SQL join for performance with proper polymorphic association filtering
- Includes Pagy::Backend for pagination functionality
- Item type filtering ensures only songs are returned (polymorphic safety)
- Higher limit (100) than typical pagination due to ranked list browsing patterns
- Type validation prevents accidentally displaying wrong media type rankings

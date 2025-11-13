# Admin::Music::Songs::RankingConfigurationsController

## Summary
Controller for managing song ranking configurations in the custom admin interface. Extends the base ranking configurations controller with song-specific paths and model class.

## Purpose
- Provides CRUD interface for `Music::Songs::RankingConfiguration`
- Handles action execution for song ranking operations
- Routes requests to song-specific views and paths

## Inheritance
- `< Admin::Music::RankingConfigurationsController` - Inherits all CRUD and action functionality

## Model Class
- `Music::Songs::RankingConfiguration`

## Routes
- Index: `/admin/songs/ranking_configurations`
- Show: `/admin/songs/ranking_configurations/:id`
- New: `/admin/songs/ranking_configurations/new`
- Edit: `/admin/songs/ranking_configurations/:id/edit`
- Execute Action: `/admin/songs/ranking_configurations/:id/execute_action` (POST)
- Index Action: `/admin/songs/ranking_configurations/index_action` (POST)

## Protected Methods (Overrides)

### `#ranking_configuration_class`
Returns the song ranking configuration model class.
- Returns: `Music::Songs::RankingConfiguration`

### `#ranking_configurations_path`
Returns the path to the song ranking configurations index.
- Returns: String path to index

### `#ranking_configuration_path(config)`
Returns the path to a specific song ranking configuration.
- Parameters: `config` (Music::Songs::RankingConfiguration)
- Returns: String path to show page

### `#table_partial_path`
Returns the path to the songs table partial.
- Returns: String partial path

## Related Classes
- `Music::Songs::RankingConfiguration` - Model for song rankings
- `Admin::Music::RankingConfigurationsController` - Base controller
- `Actions::Admin::Music::BulkCalculateWeights` - Weight calculation action
- `Actions::Admin::Music::RefreshRankings` - Ranking refresh action

## File Location
`app/controllers/admin/music/songs/ranking_configurations_controller.rb`

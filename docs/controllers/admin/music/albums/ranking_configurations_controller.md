# Admin::Music::Albums::RankingConfigurationsController

## Summary
Controller for managing album ranking configurations in the custom admin interface. Extends the base ranking configurations controller with album-specific paths and model class.

## Purpose
- Provides CRUD interface for `Music::Albums::RankingConfiguration`
- Handles action execution for album ranking operations
- Routes requests to album-specific views and paths

## Inheritance
- `< Admin::Music::RankingConfigurationsController` - Inherits all CRUD and action functionality

## Model Class
- `Music::Albums::RankingConfiguration`

## Routes
- Index: `/admin/albums/ranking_configurations`
- Show: `/admin/albums/ranking_configurations/:id`
- New: `/admin/albums/ranking_configurations/new`
- Edit: `/admin/albums/ranking_configurations/:id/edit`
- Execute Action: `/admin/albums/ranking_configurations/:id/execute_action` (POST)
- Index Action: `/admin/albums/ranking_configurations/index_action` (POST)

## Protected Methods (Overrides)

### `#ranking_configuration_class`
Returns the album ranking configuration model class.
- Returns: `Music::Albums::RankingConfiguration`

### `#ranking_configurations_path`
Returns the path to the album ranking configurations index.
- Returns: String path to index

### `#ranking_configuration_path(config)`
Returns the path to a specific album ranking configuration.
- Parameters: `config` (Music::Albums::RankingConfiguration)
- Returns: String path to show page

### `#table_partial_path`
Returns the path to the albums table partial.
- Returns: String partial path

## Related Classes
- `Music::Albums::RankingConfiguration` - Model for album rankings
- `Admin::Music::RankingConfigurationsController` - Base controller
- `Actions::Admin::Music::BulkCalculateWeights` - Weight calculation action
- `Actions::Admin::Music::RefreshRankings` - Ranking refresh action

## File Location
`app/controllers/admin/music/albums/ranking_configurations_controller.rb`

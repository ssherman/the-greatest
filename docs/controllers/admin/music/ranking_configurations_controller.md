# Admin::Music::RankingConfigurationsController

## Summary
Base controller for managing ranking configurations in the custom admin interface. Provides shared CRUD operations and action execution endpoints for both Albums and Songs ranking configurations. This is an abstract base controller that must be subclassed.

## Purpose
- Provides shared CRUD functionality for ranking configurations across different media types
- Handles action execution for both index-level and single-record actions
- Implements search, sorting, and pagination
- Enforces authorization and authentication requirements

## Inheritance
- `< Admin::Music::BaseController` - Inherits admin authentication and authorization

## Subclasses
- `Admin::Music::Albums::RankingConfigurationsController` - Albums-specific implementation
- `Admin::Music::Songs::RankingConfigurationsController` - Songs-specific implementation

## Actions

### Standard CRUD
- `index` - Lists ranking configurations with search and pagination
- `show` - Displays single ranking configuration with associated data
- `new` - Renders form for new ranking configuration
- `create` - Creates new ranking configuration
- `edit` - Renders edit form
- `update` - Updates existing ranking configuration
- `destroy` - Deletes ranking configuration

### Action Execution
- `execute_action` - Executes actions on a single ranking configuration (show page)
- `index_action` - Executes actions on multiple ranking configurations (index page)

## Protected Methods (Must Override in Subclasses)

### `#ranking_configuration_class`
Returns the model class for this controller's ranking configurations.
- Returns: Class (e.g., `Music::Albums::RankingConfiguration`)
- Raises: `NotImplementedError` if not overridden

### `#ranking_configurations_path`
Returns the path helper for the index page.
- Returns: String path
- Raises: `NotImplementedError` if not overridden

### `#ranking_configuration_path(config)`
Returns the path helper for a single ranking configuration.
- Parameters: `config` (RankingConfiguration) - The configuration to link to
- Returns: String path
- Raises: `NotImplementedError` if not overridden

### `#table_partial_path`
Returns the path to the table partial for index view.
- Returns: String partial path
- Raises: `NotImplementedError` if not overridden

## Private Methods

### `#set_ranking_configuration`
Before action that loads the ranking configuration from params.
- Sets: `@ranking_configuration`

### `#load_ranking_configurations_for_index`
Loads and filters ranking configurations for index page.
- Handles search via `params[:q]`
- Applies sorting via `params[:sort]`
- Sets: `@ranking_configurations`, `@pagy`

### `#sortable_column(column)`
Whitelists sortable columns to prevent SQL injection.
- Parameters: `column` (String) - The requested sort column
- Returns: String - SQL column name or default
- Allowed columns: id, name, algorithm_version, published_at, created_at

### `#ranking_configuration_params`
Strong parameters for ranking configuration.
- Returns: ActionController::Parameters
- Permits: name, description, global, primary, archived, published_at, algorithm_version, exponent, bonus_pool_percentage, min_list_weight, list_limit, apply_list_dates_penalty, max_list_dates_penalty_age, max_list_dates_penalty_percentage, primary_mapped_list_id, secondary_mapped_list_id, primary_mapped_list_cutoff_limit

## Security
- Requires admin or editor role (enforced by `Admin::Music::BaseController`)
- SQL injection prevented via sortable column whitelist
- Strong parameters enforce permitted attributes

## Response Formats
- HTML - Standard page rendering
- Turbo Stream - For AJAX updates on action execution

## Related Classes
- `Music::Albums::RankingConfiguration` - Model for album rankings
- `Music::Songs::RankingConfiguration` - Model for song rankings
- `Actions::Admin::Music::BulkCalculateWeights` - Action for weight recalculation
- `Actions::Admin::Music::RefreshRankings` - Action for ranking refresh
- `Admin::Music::RankedItemsController` - Manages ranked items display
- `Admin::Music::RankedListsController` - Manages ranked lists display

## File Location
`app/controllers/admin/music/ranking_configurations_controller.rb`

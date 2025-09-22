# RankedItemsController

## Summary
Base controller for displaying ranked items across all media types. Provides common functionality for ranking configuration management, validation, and error handling.

## Associations
- None (base controller)

## Public Methods

### `self.expected_ranking_configuration_type`
Returns the expected RankingConfiguration type for this controller
- Returns: String or nil - The STI type expected (e.g., "Music::Albums::RankingConfiguration")
- Override in subclasses to specify expected type

## Private Methods

### `#find_ranking_configuration`
Finds and loads the appropriate ranking configuration based on params
- Uses `params[:ranking_configuration_id]` if present, otherwise loads global primary
- Sets `@ranking_configuration` instance variable
- Raises `ActiveRecord::RecordNotFound` if no configuration found

### `#validate_ranking_configuration_type`
Validates that the loaded ranking configuration matches the expected type
- Uses `self.class.expected_ranking_configuration_type` for validation
- Raises `ActiveRecord::RecordNotFound` if type doesn't match

## Dependencies
- RankingConfiguration model
- ApplicationController (inherits from)
- Pagy gem for pagination

## Design Notes
- Uses inheritance hierarchy for extensibility across media types
- Type validation ensures proper ranking configuration usage
- Error handling converts exceptions to 404 responses via ApplicationController

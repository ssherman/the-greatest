# RankingConfigurations::RefreshRankings

## Summary
Avo admin action for manually triggering ranking recalculation. Provides one-click refresh of rankings from the admin interface.

## Associations
- Operates on `RankingConfiguration` resources in Avo admin interface
- Triggers background job that updates `RankedItem` records

## Public Methods

### `#handle(query:, fields:, current_user:, resource:, **)`
Handles the admin action execution for selected ranking configurations
- Parameters: Standard Avo action parameters with query for selected records
- Returns: void (uses Avo redirect and messages)
- Side effects: Enqueues CalculateRankingsJob for each selected configuration

## Validations
None - validates configuration existence through Avo resource selection

## Scopes
None - Avo action class

## Constants
None

## Callbacks
None

## Dependencies
- Avo framework for admin interface
- CalculateRankingsJob for background processing
- RankingConfiguration model for target resources
# Admin::Music::RankedListsController

## Summary
Controller for displaying paginated ranked lists within a ranking configuration. Provides inline, lazy-loaded display of lists with calculated weights via Turbo Frames. Handles both album and song ranked lists.

## Purpose
- Displays paginated list of ranked lists for a ranking configuration
- Shows calculated weights and weight details
- Supports both Albums and Songs ranking configurations
- Renders without layout for Turbo Frame embedding
- Prevents N+1 queries via eager loading

## Inheritance
- `< Admin::Music::BaseController` - Inherits admin authentication and authorization

## Actions

### `index`
Returns paginated ranked lists for a ranking configuration.
- Query Params:
  - `ranking_configuration_id` (required) - ID of parent ranking configuration
  - `page` (optional) - Page number for pagination
- Sets: `@ranking_configuration`, `@ranked_lists`, `@pagy`
- Response: HTML partial (no layout)
- Pagination: 25 lists per page

## Sorting
- Fixed sort order: `weight DESC` (highest weight first)
- No user-configurable sorting (removed for simplicity)

## Eager Loading
Prevents N+1 queries by including:
- `list` - The ranked list
- `list.submitted_by` - User who submitted the list

## View Behavior
- Displays list name with submitter information
- Weight shown as badge
- Calculated weight details shown in expandable dropdown with JSON formatting
- Empty state shown when no lists included in configuration

## Display Format
Table columns:
- List Name - Name with optional submitter email
- Weight - Badge display of calculated weight (2 decimal places)
- Calculated Weight Details - Expandable JSON view of weight calculation

## Weight Details Display
- Stored in `calculated_weight_details` JSONB field
- Displayed as formatted JSON in expandable details element
- Shows penalty calculations and adjustments

## Security
- Requires admin or editor role (enforced by base controller)
- No SQL injection risk (fixed sort order)

## Performance
- Pagination: 25 lists per page
- Eager loading: `.includes(list: :submitted_by)`
- Turbo Frame: Lazy loading prevents blocking main page render

## Related Classes
- `RankingConfiguration` - Parent model (polymorphic - Albums or Songs)
- `RankedList` - Model representing lists included in ranking
- `Music::Albums::List` - List model for album rankings
- `Music::Songs::List` - List model for song rankings
- `User` - List submitter

## File Location
`app/controllers/admin/music/ranked_lists_controller.rb`

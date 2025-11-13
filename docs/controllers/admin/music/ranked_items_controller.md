# Admin::Music::RankedItemsController

## Summary
Controller for displaying paginated ranked items within a ranking configuration. Provides inline, lazy-loaded display of ranked results via Turbo Frames. Handles both album and song ranked items.

## Purpose
- Displays paginated list of ranked items for a ranking configuration
- Supports both Albums and Songs ranking configurations
- Renders without layout for Turbo Frame embedding
- Prevents N+1 queries via eager loading

## Inheritance
- `< Admin::Music::BaseController` - Inherits admin authentication and authorization

## Actions

### `index`
Returns paginated ranked items for a ranking configuration.
- Query Params:
  - `ranking_configuration_id` (required) - ID of parent ranking configuration
  - `page` (optional) - Page number for pagination
- Sets: `@ranking_configuration`, `@ranked_items`, `@pagy`
- Response: HTML partial (no layout)
- Pagination: 25 items per page

## Sorting
- Fixed sort order: `rank ASC`
- No user-configurable sorting (removed for simplicity)

## Eager Loading
Prevents N+1 queries by including:
- `item` - The ranked album or song
- `item.artists` - Artists associated with the item

## View Behavior
- Renders different content based on `@ranking_configuration.type`:
  - `Music::Albums::RankingConfiguration` - Links to album and artist admin pages
  - `Music::Songs::RankingConfiguration` - Links to song and artist admin pages
- Artist names are clickable links to artist admin pages
- Empty state shown when no rankings calculated

## Display Format
Table columns:
- Rank - Badge display of rank number
- Item - Title linked to admin page, with artist links
- Score - Formatted to 2 decimal places

## Security
- Requires admin or editor role (enforced by base controller)
- No SQL injection risk (fixed sort order)

## Performance
- Pagination: 25 items per page
- Eager loading: `.includes(item: :artists)`
- Turbo Frame: Lazy loading prevents blocking main page render

## Related Classes
- `RankingConfiguration` - Parent model (polymorphic - Albums or Songs)
- `RankedItem` - Model representing ranked results
- `Music::Album` - Item model for album rankings
- `Music::Song` - Item model for song rankings
- `Music::Artist` - Associated artists

## File Location
`app/controllers/admin/music/ranked_items_controller.rb`

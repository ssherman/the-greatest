# Music::Albums::CategoriesController

## Summary
Displays all ranked albums within a specific music category with pagination and ranking configuration support. This controller provides a focused browsing experience for exploring albums by category (genre, location, or subject) with support for different ranking configurations.

## Routes
- `GET /albums/categories/:id` - Albums in category with default ranking
- `GET /rc/:ranking_configuration_id/albums/categories/:id` - Albums in category with specific ranking configuration

## Actions

### `show`
Displays paginated list of all ranked albums in the category.

**Parameters:**
- `id` (String, required) - Category slug (FriendlyId)
- `ranking_configuration_id` (Integer, optional) - ID of ranking configuration (defaults to primary)

**Instance Variables:**
- `@category` - The Music::Category being displayed
- `@ranking_configuration` - The active album ranking configuration (set by `load_ranking_configuration`)
- `@pagy` - Pagy pagination object
- `@albums` - Paginated RankedItem collection (100 per page)

**Response:**
- 200 OK - Renders album category page
- 404 Not Found - Category does not exist, is soft-deleted, or ranking configuration not found/wrong type

## Class Methods

### `self.ranking_configuration_class`
Specifies the ranking configuration class for this controller.

**Returns:** `Music::Albums::RankingConfiguration`

**Purpose:** Used by ApplicationController's `load_ranking_configuration` to determine which ranking configuration type to load.

## Callbacks

### `before_action :load_ranking_configuration`
Loads the ranking configuration before the show action.

**Behavior:**
1. Checks for `params[:ranking_configuration_id]`
2. If present, loads that specific configuration (validates it's the correct type)
3. If not present, loads `Music::Albums::RankingConfiguration.default_primary`
4. Raises 404 if ranking configuration not found or wrong type
5. Sets `@ranking_configuration` instance variable

## Private Methods

### `build_ranked_albums_query`
Builds optimized query for ranked albums in the category.

**Logic:**
1. Returns empty relation if no ranking configuration loaded
2. Joins RankedItem → CategoryItem → Music::Album tables
3. Filters by:
   - Item type: "Music::Album"
   - Ranking configuration ID
   - Category ID
4. Eager loads associations (artists, categories, primary_image) to prevent N+1 queries
5. Orders by rank ascending (best first)

**Returns:** ActiveRecord::Relation of RankedItem

**Query Pattern:**
```ruby
RankedItem
  .joins("JOIN category_items ON category_items.item_id = ranked_items.item_id AND category_items.item_type = 'Music::Album'")
  .joins("JOIN music_albums ON music_albums.id = ranked_items.item_id")
  .where(item_type: "Music::Album", ranking_configuration_id: rc_id, category_items: {category_id: cat_id})
  .includes(item: [:artists, :categories, :primary_image])
  .order(:rank)
```

## Pagination
Uses Pagy gem with 100 items per page:
- Standard pagination controls (no infinite scroll)
- URL parameter: `page=N`
- Compatible with Turbo (full page navigation, not Turbo Frames)

## Ranking Configuration Support
This controller supports multiple ranking configurations:
- **With RC ID**: `/rc/123/albums/categories/progressive-rock` - Uses specific ranking
- **Without RC ID**: `/albums/categories/progressive-rock` - Uses default primary ranking

The ranking configuration determines which calculated ranks are displayed and in what order.

## Layout
Uses `music/application` layout for consistent Music domain styling and navigation.

## View Component
Uses `Music::Albums::RankedCardComponent` for consistent album card rendering across the application.

## Related Controllers
- [Music::CategoriesController](../categories_controller.md) - Category overview page (entry point)
- [Music::Artists::CategoriesController](../artists/categories_controller.md) - Parallel controller for artist category browsing

## Dependencies
- ApplicationController's `load_ranking_configuration` method
- Music::Category model with FriendlyId support
- Music::Albums::RankingConfiguration with default_primary scope
- RankedItem model
- CategoryItem join model
- Pagy gem for pagination
- FriendlyId gem for slug-based routing
- [Music::Albums::RankedCardComponent](../../components/music/albums/ranked_card_component.md) for album card rendering

## Query Optimization
- Join-based filtering (database-level, efficient)
- Eager loading with `.includes()` prevents N+1 queries
- Albums include artists, categories, and primary_image associations
- Indexes expected on:
  - ranked_items (item_type, ranking_configuration_id, rank)
  - category_items (category_id, item_id, item_type)

## SEO
The view includes:
- Dynamic page title: "{Category Name} Albums | The Greatest Music"
- Back link to main category overview page
- Clean URLs using category slugs
- Pagination links rel="next"/"prev" for SEO

## Usage Examples
```
# Default ranking
GET /albums/categories/progressive-rock
→ Shows all Progressive Rock albums ranked by default primary configuration
→ 100 albums per page
→ Links back to /categories/progressive-rock

# Custom ranking configuration
GET /rc/42/albums/categories/progressive-rock
→ Shows all Progressive Rock albums ranked by configuration #42
→ Same pagination and layout
→ Validates that configuration #42 is for Music::Albums
```

## Error Handling
Returns 404 if:
- Category slug not found
- Category is soft-deleted (inactive)
- Ranking configuration ID not found
- Ranking configuration is wrong type (e.g., artist RC instead of album RC)

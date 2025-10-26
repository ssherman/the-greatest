# Music::CategoriesController

## Summary
Main category overview controller that displays top artists and albums for a music category. This controller serves as the entry point for category-based music discovery, showing a preview of the best content in each category with links to dedicated artist and album category pages.

## Routes
- `GET /categories/:id` - Category overview page (uses FriendlyId slug)

## Actions

### `show`
Displays category overview with top 10 ranked artists and top 10 ranked albums.

**Parameters:**
- `id` (String, required) - Category slug (FriendlyId)

**Instance Variables:**
- `@category` - The Music::Category being displayed
- `@artist_rc` - Default primary artist ranking configuration
- `@album_rc` - Default primary album ranking configuration
- `@artists` - Top 10 ranked artists in this category
- `@albums` - Top 10 ranked albums in this category

**Response:**
- 200 OK - Renders category overview page
- 404 Not Found - Category does not exist or is soft-deleted

## Private Methods

### `build_ranked_artists_query`
Builds optimized query for ranked artists in the category.

**Logic:**
1. Returns empty relation if no artist ranking configuration exists
2. Joins RankedItem → CategoryItem → Music::Artist
3. Filters by artist type, ranking configuration, and category
4. Eager loads artist associations (categories, primary_image)
5. Orders by rank ascending (best first)

**Returns:** ActiveRecord::Relation of RankedItem

### `build_ranked_albums_query`
Builds optimized query for ranked albums in the category.

**Logic:**
1. Returns empty relation if no album ranking configuration exists
2. Joins RankedItem → CategoryItem → Music::Album
3. Filters by album type, ranking configuration, and category
4. Eager loads album associations (artists, categories, primary_image)
5. Orders by rank ascending (best first)

**Returns:** ActiveRecord::Relation of RankedItem

## Ranking Configuration Strategy
**Important:** This controller always uses default primary ranking configurations and does NOT accept ranking_configuration_id parameter. This ensures:
- Consistent "canonical best" view for all users
- Clean, cacheable URLs without RC parameters
- Single source of truth for category overviews
- Simplified UX (no ranking configuration selection)

For custom ranking configurations, users should navigate to dedicated artist or album category pages which support RC parameters.

## Query Optimization
Both query methods use:
- Join-based filtering (efficient, database-level)
- Eager loading with `.includes()` to prevent N+1 queries
- Limit applied at controller level (10 items each)
- Rank-based ordering for consistent results

## Layout
Uses `music/application` layout for consistent Music domain styling and navigation.

## Related Controllers
- [Music::Artists::CategoriesController](music/artists/categories_controller.md) - Full artist category browsing with pagination and RC support
- [Music::Albums::CategoriesController](music/albums/categories_controller.md) - Full album category browsing with pagination and RC support

## Dependencies
- Music::Category model with FriendlyId support
- Music::Artists::RankingConfiguration with default_primary scope
- Music::Albums::RankingConfiguration with default_primary scope
- RankedItem model
- CategoryItem join model
- FriendlyId gem for slug-based routing

## SEO
The view includes:
- Dynamic page title: "{Category Name} - {Type} | The Greatest Music"
- Dynamic meta description based on category type
- Category description if available
- Clean URLs using category slugs

## Usage Example
```
GET /categories/progressive-rock
→ Shows top 10 Progressive Rock artists and top 10 Progressive Rock albums
→ Links to /artists/categories/progressive-rock (see all artists)
→ Links to /albums/categories/progressive-rock (see all albums)
```

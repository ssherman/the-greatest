# Music::Artists::RankedItemsController

## Summary
Public-facing controller that displays "The Greatest Artists" rankings page. Shows a paginated list of artists sorted by rank, based on the default primary artist ranking configuration.

## Purpose
Provides the user-facing interface for browsing artist rankings. This is the controller behind the `/artists` route on the music domain (thegreatestmusic.org).

## Layout
Uses `music/application` layout (shared with other music domain pages).

## Actions

### `index`
Displays the artist rankings page with pagination.

**Route:** `GET /artists` or `GET /artists/page/:page`

**Parameters:** None (pagination handled by Pagy via path segments)

**Instance Variables:**
- `@ranking_configuration` (Music::Artists::RankingConfiguration) - The default primary artist ranking config
- `@artists` (Array<RankedItem>) - Paginated array of ranked items (ordered by rank)
- `@pagy` (Pagy) - Pagination object (or nil if no configuration exists)

**Behavior:**
1. Fetches the default primary artist ranking configuration
2. If no configuration exists, sets empty arrays and returns early (shows empty state)
3. Builds a query for ranked_items with:
   - Join to music_artists table (for eager loading)
   - Includes associations (categories, primary_image) to avoid N+1 queries
   - Filters by item_type "Music::Artist"
   - Orders by rank (ascending)
4. Paginates with Pagy (100 artists per page)
5. Renders `music/artists/ranked_items/index.html.erb`

**Database Query:**
```ruby
ranked_items
  .joins("JOIN music_artists ON ranked_items.item_id = music_artists.id AND ranked_items.item_type = 'Music::Artist'")
  .includes(item: [:categories, :primary_image])
  .where(item_type: "Music::Artist")
  .order(:rank)
```

**Performance:**
- Single database query for ranked_items
- Eager loads artist associations to avoid N+1
- Uses database joins for efficiency
- Pagination limits to 100 records per page

**Empty State:**
If no ranking configuration exists:
- `@artists` is set to empty array
- `@pagy` is set to nil
- View renders "No artists found" message

**View Template:** `app/views/music/artists/ranked_items/index.html.erb`

## URL Structure

Unlike albums and songs which support optional ranking configuration parameters, artist rankings use a simpler URL structure:

**Albums:** `/albums` or `/rc/:id/albums` (supports rc parameter)

**Songs:** `/songs` or `/rc/:id/songs` (supports rc parameter)

**Artists:** `/artists` (always uses default primary configs, no rc parameter)

**Rationale:** Artist rankings depend on TWO ranking configurations (albums and songs), so a single `rc` parameter doesn't make sense. The controller always uses the default primary configuration.

## Pagination

**Path-based Pagination:**
- Page 1: `/artists`
- Page 2: `/artists/page/2`
- Page 3: `/artists/page/3`

**Why Path-based?**
- Enables CDN and reverse proxy caching
- Better SEO (search engines can crawl pages)
- Cleaner URLs than query parameters (`?page=2`)

**Items Per Page:** 100 artists (matches albums/songs pattern)

## SEO Optimization

The view includes SEO metadata:
```erb
content_for :page_title, "Greatest Artists of All Time Ranked | The Greatest Music"
content_for :meta_description, "Discover our definitive ranking of the greatest music artists of all time. Based on their acclaimed albums and songs, explore the artists who shaped music history."
```

## Dependencies

**Models:**
- `Music::Artists::RankingConfiguration` - Artist ranking configuration
- `RankedItem` - Polymorphic model storing artist rankings
- `Music::Artist` - Artist data

**Gems:**
- `pagy` - Pagination

**Concerns:**
- `Pagy::Backend` - Provides `pagy` helper method

## Navigation
Accessible via the "Artists" link in the music domain navigation menu.

**Navigation Code:**
```erb
<li><%= link_to "Artists", artists_path %></li>
```

## View Data

**For Each Artist:**
- Rank number (`ranked_item.rank`)
- Artist name (`artist.name`)
- Artist kind (`artist.kind` - e.g., "person", "band")
- Primary image (`artist.primary_image`)
- Categories (`artist.categories`)

**View displays:**
- Grid of artist cards (4 columns on desktop)
- Rank badge
- Artist image or placeholder
- Artist name
- Artist kind (person/band)
- Up to 3 categories (with "+X more" indicator)

## Related Routes

**Routes Configuration:**
```ruby
# Artist rankings - OUTSIDE the rc scope
get "artists", to: "music/artists/ranked_items#index", as: :artists
get "artists/page/:page", to: "music/artists/ranked_items#index"
```

**Path Helpers:**
- `artists_path` - `/artists`
- `artists_path(page: 2)` - Not supported (use `/artists/page/2`)

## Error Handling

**Missing Configuration:**
- Gracefully handles missing ranking configuration
- Shows empty state instead of error
- Admin should create configuration via Avo

**No Ranked Artists:**
- Shows "No artists found" message
- Indicates rankings haven't been calculated yet
- Admin should trigger ranking calculation

## Testing

**Test Coverage:**
- Index action with default configuration
- Path-based pagination (`/artists/page/2`)
- Graceful handling of missing configuration

**Test File:** `test/controllers/music/artists/ranked_items_controller_test.rb`

## Related Documentation
- [Music::Artists::RankingConfiguration](/home/shane/dev/the-greatest/docs/models/music/artists/ranking_configuration.md)
- [ItemRankings::Music::Artists::Calculator](/home/shane/dev/the-greatest/docs/lib/item_rankings/music/artists/calculator.md)
- [Music::Artist](/home/shane/dev/the-greatest/docs/models/music/artist.md)

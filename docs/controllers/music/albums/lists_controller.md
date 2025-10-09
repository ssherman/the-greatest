# Music::Albums::ListsController

## Summary
Controller for browsing and viewing album lists in the music domain. Provides paginated list browsing with sorting options and detailed individual list views with full album information.

## Purpose
Handles all user interactions with album lists, including:
- Browsing all album lists with pagination
- Sorting lists by weight (influence) or creation date
- Viewing individual lists with full album and artist details
- Displaying list rankings and weights within a ranking configuration

## Actions

### `index`
Displays a paginated list of all album lists, optionally filtered by a specific ranking configuration.

**Parameters:**
- `sort` (optional) - Sort order: `"created_at"` for newest first, default is weight descending
- `ranking_configuration_id` (optional) - Specific ranking configuration ID, defaults to primary

**Query Strategy:**
```ruby
sort_order = params[:sort] == "created_at" ? { "lists.created_at": :desc } : { weight: :desc }

ranked_lists_query = @ranking_configuration.ranked_lists
  .joins(:list)
  .where(lists: { type: "Music::Albums::List" })
  .includes(list: :list_items)
  .order(sort_order)

@pagy, @ranked_lists = pagy(ranked_lists_query, limit: 25)
```

**Instance Variables Set:**
- `@ranking_configuration` - The active ranking configuration (Music::Albums::RankingConfiguration)
- `@pagy` - Pagination object from Pagy gem
- `@ranked_lists` - Paginated array of RankedList objects (25 per page)

**Sorting Options:**
- **Default (weight)**: Lists with highest influence/weight appear first
- **Created at**: Newest lists appear first

### `show`
Displays a single album list with all albums, artists, and images included.

**Parameters:**
- `id` (required) - The List ID to display
- `ranking_configuration_id` (optional) - Specific ranking configuration ID, defaults to primary

**Query Strategy:**
```ruby
@list = Music::Albums::List.includes(list_items: { listable: [:artists, :primary_image] })
  .find(params[:id])

@ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)
```

**Instance Variables Set:**
- `@list` - The Music::Albums::List being displayed
- `@ranked_list` - The RankedList association (may be nil if not in current configuration)
- `@ranking_configuration` - The active ranking configuration

**Eager Loading:**
- `list_items` - All items in the list
- `listable` (Album) - The album for each list item
- `artists` - All artists for each album
- `primary_image` - The cover art for each album

**Raises:**
- `ActiveRecord::RecordNotFound` - If list ID doesn't exist

## Routing

**Routes:**
```ruby
# config/routes.rb
get "albums/lists", to: "music/albums/lists#index", as: :music_albums_lists
get "albums/lists/:id", to: "music/albums/lists#show", as: :music_album_list
```

**URL Patterns:**
- `/music/albums/lists` - Browse all album lists
- `/music/albums/lists?sort=created_at` - Browse newest lists first
- `/music/albums/lists?ranking_configuration_id=123` - Filter by specific ranking config
- `/music/albums/lists/456` - View specific album list

**Named Routes:**
- `music_albums_lists_path` - Index action helper
- `music_album_list_path(list)` - Show action helper

## Configuration

### Layout
Uses `music/application` layout for consistent music domain styling.

### Included Modules
- `Pagy::Backend` - Provides pagination functionality via Pagy gem

### Callbacks
- `before_action :find_ranking_configuration` - Loads the ranking configuration for all actions
- `before_action :validate_ranking_configuration_type` - Ensures configuration is correct type

## Class Methods

### `self.ranking_configuration_class`
Returns the expected ranking configuration class for type validation.

**Returns:** `Music::Albums::RankingConfiguration`

**Purpose:** Used by validation to ensure the ranking configuration matches the controller's domain (albums).

## Private Methods

### `find_ranking_configuration`
Loads the appropriate ranking configuration from params or defaults to primary.

**Implementation:**
```ruby
def find_ranking_configuration
  @ranking_configuration = if params[:ranking_configuration_id].present?
    RankingConfiguration.find(params[:ranking_configuration_id])
  else
    self.class.ranking_configuration_class.default_primary
  end

  raise ActiveRecord::RecordNotFound unless @ranking_configuration
end
```

**Logic:**
1. If `ranking_configuration_id` param provided, load that specific configuration
2. Otherwise, load the default primary configuration for albums
3. Raise 404 if configuration not found

**Raises:**
- `ActiveRecord::RecordNotFound` - If configuration doesn't exist or is nil

### `validate_ranking_configuration_type`
Ensures the loaded ranking configuration is the correct type for this controller.

**Implementation:**
```ruby
def validate_ranking_configuration_type
  expected_class = self.class.ranking_configuration_class
  return if expected_class == RankingConfiguration

  unless @ranking_configuration.is_a?(expected_class)
    raise ActiveRecord::RecordNotFound
  end
end
```

**Purpose:**
- Prevents using a Songs ranking configuration in the Albums controller
- Ensures type safety across domain boundaries
- Returns 404 if types don't match

**Raises:**
- `ActiveRecord::RecordNotFound` - If configuration type doesn't match expected type

## Dependencies

### Models
- `Music::Albums::RankingConfiguration` - Album-specific ranking configuration
- `RankingConfiguration` - Base ranking configuration model
- `Music::Albums::List` - Album-specific list model (STI)
- `RankedList` - Join model between lists and ranking configurations
- `ListItem` - Items within each list
- `Music::Album` - Album model (via listable polymorphic association)
- `Music::Artist` - Artist model (associated with albums)
- `Image` - Image model for album artwork

### Gems
- `pagy` - Pagination library (more performant than Kaminari/WillPaginate)

### Concerns
None - inherits from ApplicationController

## Views
- `app/views/music/albums/lists/index.html.erb` - List browsing page with pagination
- `app/views/music/albums/lists/show.html.erb` - Individual list detail page

## Usage Examples

### Browsing Album Lists
```ruby
# Default view - sorted by weight
music_albums_lists_path  # => "/music/albums/lists"

# Sorted by newest first
music_albums_lists_path(sort: "created_at")  # => "/music/albums/lists?sort=created_at"

# Specific ranking configuration
music_albums_lists_path(ranking_configuration_id: 123)
# => "/music/albums/lists?ranking_configuration_id=123"
```

### Viewing Individual List
```ruby
# Show specific list
music_album_list_path(123)  # => "/music/albums/lists/123"

# With specific ranking configuration
music_album_list_path(123, ranking_configuration_id: 456)
# => "/music/albums/lists/123?ranking_configuration_id=456"
```

### Pagination in Views
```erb
<!-- In index.html.erb -->
<%= pagy_nav(@pagy) %>

<% @ranked_lists.each do |ranked_list| %>
  <%= link_to ranked_list.list.name, music_album_list_path(ranked_list.list) %>
  Weight: <%= ranked_list.weight %>
<% end %>
```

### Accessing List Data in Show View
```erb
<!-- In show.html.erb -->
<h1><%= @list.name %></h1>
<p>Weight: <%= @ranked_list&.weight || "Not ranked" %></p>

<% @list.list_items.each do |item| %>
  <%= item.listable.title %> <!-- Album title -->
  by <%= item.listable.artists.map(&:name).join(", ") %>
  <%= image_tag item.listable.primary_image.url if item.listable.primary_image %>
<% end %>
```

## Design Notes

### STI Type Filtering
The controller filters by `type: "Music::Albums::List"` to ensure only album lists are shown:
- Rails uses Single Table Inheritance (STI) for different list types
- All lists stored in same `lists` table with a `type` column
- Filtering by type ensures songs lists don't appear in album browsing

### Ranking Configuration Flexibility
The controller supports both primary and custom ranking configurations:
- **Primary (default)**: The main, global album ranking configuration
- **Custom**: Users can view lists through different ranking lenses
- This enables A/B testing of ranking algorithms and user-specific rankings

### Pagination Strategy
- Uses Pagy gem (lighter and faster than alternatives)
- 25 items per page balances performance and usability
- Server-side pagination prevents loading all lists at once
- Compatible with Turbo/Hotwire for smooth page transitions

### Eager Loading Strategy
The show action uses deep eager loading to prevent N+1 queries:
```ruby
.includes(list_items: { listable: [:artists, :primary_image] })
```

This single query loads:
1. The list
2. All list items
3. All albums (via listable polymorphic association)
4. All artists for each album
5. Primary image for each album

Without this, rendering a 50-item list would trigger 150+ queries.

### Type Validation Pattern
The type validation is defensive programming:
- Prevents edge cases where wrong configuration type is passed
- Provides consistent error handling (404 instead of runtime errors)
- Shared pattern across all domain-specific list controllers

## Security Considerations
- All queries scoped to public lists (no authorization needed for viewing)
- Type validation prevents cross-domain data leakage
- No user input directly interpolated into queries (uses Rails query interface)

## Performance Optimizations
- **Pagination**: Only loads 25 records per request
- **Eager Loading**: Prevents N+1 queries with deep includes
- **Index Hints**: Queries leverage database indexes on weight and created_at
- **Limit Results**: Never loads entire ranked_lists table

## Future Enhancements
- Add filtering by date ranges or list metadata
- Support user-created ranking configurations
- Add caching for frequently accessed lists
- Implement list search functionality
- Add export functionality (CSV, JSON)

## Related Documentation
- [Music::Songs::ListsController](../songs/lists_controller.md) - Parallel controller for songs
- [Music::ListsController](../lists_controller.md) - Overview controller for all music lists
- [RankedList Model](../../../models/ranked_list.md)
- [RankingConfiguration Model](../../../models/ranking_configuration.md)
- [Music::Albums::List Model](../../../models/music/albums/list.md)
- [Music::Album Model](../../../models/music/album.md)

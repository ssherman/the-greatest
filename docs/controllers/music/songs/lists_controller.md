# Music::Songs::ListsController

## Summary
Controller for browsing and viewing song lists in the music domain. Provides paginated list browsing with sorting options and detailed individual list views with full song and artist information.

## Purpose
Handles all user interactions with song lists, including:
- Browsing all song lists with pagination
- Sorting lists by weight (influence) or creation date
- Viewing individual lists with full song and artist details
- Displaying list rankings and weights within a ranking configuration

## Actions

### `index`
Displays a paginated list of all song lists, optionally filtered by a specific ranking configuration.

**Parameters:**
- `sort` (optional) - Sort order: `"created_at"` for newest first, default is weight descending
- `ranking_configuration_id` (optional) - Specific ranking configuration ID, defaults to primary

**Query Strategy:**
```ruby
sort_order = params[:sort] == "created_at" ? { "lists.created_at": :desc } : { weight: :desc }

ranked_lists_query = @ranking_configuration.ranked_lists
  .joins(:list)
  .where(lists: { type: "Music::Songs::List" })
  .includes(list: :list_items)
  .order(sort_order)

@pagy, @ranked_lists = pagy(ranked_lists_query, limit: 25)
```

**Instance Variables Set:**
- `@ranking_configuration` - The active ranking configuration (Music::Songs::RankingConfiguration)
- `@pagy` - Pagination object from Pagy gem
- `@ranked_lists` - Paginated array of RankedList objects (25 per page)

**Sorting Options:**
- **Default (weight)**: Lists with highest influence/weight appear first
- **Created at**: Newest lists appear first

### `show`
Displays a single song list with all songs and artists included.

**Parameters:**
- `id` (required) - The List ID to display
- `ranking_configuration_id` (optional) - Specific ranking configuration ID, defaults to primary

**Query Strategy:**
```ruby
@list = Music::Songs::List.includes(list_items: { listable: :artists })
  .find(params[:id])

@ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)
```

**Instance Variables Set:**
- `@list` - The Music::Songs::List being displayed
- `@ranked_list` - The RankedList association (may be nil if not in current configuration)
- `@ranking_configuration` - The active ranking configuration

**Eager Loading:**
- `list_items` - All items in the list
- `listable` (Song) - The song for each list item
- `artists` - All artists for each song

**Note:** Songs do not include `primary_image` in the eager loading (unlike albums), as song display may rely on album artwork or artist images instead.

**Raises:**
- `ActiveRecord::RecordNotFound` - If list ID doesn't exist

## Routing

**Routes:**
```ruby
# config/routes.rb
get "songs/lists", to: "music/songs/lists#index", as: :music_songs_lists
get "songs/lists/:id", to: "music/songs/lists#show", as: :music_song_list
```

**URL Patterns:**
- `/music/songs/lists` - Browse all song lists
- `/music/songs/lists?sort=created_at` - Browse newest lists first
- `/music/songs/lists?ranking_configuration_id=123` - Filter by specific ranking config
- `/music/songs/lists/456` - View specific song list

**Named Routes:**
- `music_songs_lists_path` - Index action helper
- `music_song_list_path(list)` - Show action helper

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

**Returns:** `Music::Songs::RankingConfiguration`

**Purpose:** Used by validation to ensure the ranking configuration matches the controller's domain (songs).

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
2. Otherwise, load the default primary configuration for songs
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
- Prevents using an Albums ranking configuration in the Songs controller
- Ensures type safety across domain boundaries
- Returns 404 if types don't match

**Raises:**
- `ActiveRecord::RecordNotFound` - If configuration type doesn't match expected type

## Dependencies

### Models
- `Music::Songs::RankingConfiguration` - Song-specific ranking configuration
- `RankingConfiguration` - Base ranking configuration model
- `Music::Songs::List` - Song-specific list model (STI)
- `RankedList` - Join model between lists and ranking configurations
- `ListItem` - Items within each list
- `Music::Song` - Song model (via listable polymorphic association)
- `Music::Artist` - Artist model (associated with songs)

### Gems
- `pagy` - Pagination library (more performant than Kaminari/WillPaginate)

### Concerns
None - inherits from ApplicationController

## Views
- `app/views/music/songs/lists/index.html.erb` - List browsing page with pagination
- `app/views/music/songs/lists/show.html.erb` - Individual list detail page

## Usage Examples

### Browsing Song Lists
```ruby
# Default view - sorted by weight
music_songs_lists_path  # => "/music/songs/lists"

# Sorted by newest first
music_songs_lists_path(sort: "created_at")  # => "/music/songs/lists?sort=created_at"

# Specific ranking configuration
music_songs_lists_path(ranking_configuration_id: 123)
# => "/music/songs/lists?ranking_configuration_id=123"
```

### Viewing Individual List
```ruby
# Show specific list
music_song_list_path(123)  # => "/music/songs/lists/123"

# With specific ranking configuration
music_song_list_path(123, ranking_configuration_id: 456)
# => "/music/songs/lists/123?ranking_configuration_id=456"
```

### Pagination in Views
```erb
<!-- In index.html.erb -->
<%= pagy_nav(@pagy) %>

<% @ranked_lists.each do |ranked_list| %>
  <%= link_to ranked_list.list.name, music_song_list_path(ranked_list.list) %>
  Weight: <%= ranked_list.weight %>
<% end %>
```

### Accessing List Data in Show View
```erb
<!-- In show.html.erb -->
<h1><%= @list.name %></h1>
<p>Weight: <%= @ranked_list&.weight || "Not ranked" %></p>

<% @list.list_items.each do |item| %>
  <%= item.listable.title %> <!-- Song title -->
  by <%= item.listable.artists.map(&:name).join(", ") %>
<% end %>
```

## Design Notes

### STI Type Filtering
The controller filters by `type: "Music::Songs::List"` to ensure only song lists are shown:
- Rails uses Single Table Inheritance (STI) for different list types
- All lists stored in same `lists` table with a `type` column
- Filtering by type ensures album lists don't appear in song browsing

### Ranking Configuration Flexibility
The controller supports both primary and custom ranking configurations:
- **Primary (default)**: The main, global song ranking configuration
- **Custom**: Users can view lists through different ranking lenses
- This enables A/B testing of ranking algorithms and user-specific rankings

### Pagination Strategy
- Uses Pagy gem (lighter and faster than alternatives)
- 25 items per page balances performance and usability
- Server-side pagination prevents loading all lists at once
- Compatible with Turbo/Hotwire for smooth page transitions

### Eager Loading Strategy
The show action uses eager loading to prevent N+1 queries:
```ruby
.includes(list_items: { listable: :artists })
```

This single query loads:
1. The list
2. All list items
3. All songs (via listable polymorphic association)
4. All artists for each song

**Difference from Albums Controller:**
Songs do not eager load `primary_image` because:
- Songs may not have direct image associations
- Song artwork often comes from the parent album
- Reduces unnecessary joins and memory usage

Without eager loading, rendering a 50-item list would trigger 100+ queries.

### Type Validation Pattern
The type validation is defensive programming:
- Prevents edge cases where wrong configuration type is passed
- Provides consistent error handling (404 instead of runtime errors)
- Shared pattern across all domain-specific list controllers

### Similarities with Albums Controller
This controller is structurally identical to `Music::Albums::ListsController` with key differences:
- Different ranking configuration class (`Music::Songs::RankingConfiguration`)
- Different list STI type (`Music::Songs::List`)
- Different eager loading strategy (no `primary_image`)
- Different routes and named route helpers

This parallel structure allows for:
- Consistent user experience across albums and songs
- Code reuse patterns and testing strategies
- Easy addition of new music media types (e.g., Music::Playlists)

## Security Considerations
- All queries scoped to public lists (no authorization needed for viewing)
- Type validation prevents cross-domain data leakage
- No user input directly interpolated into queries (uses Rails query interface)

## Performance Optimizations
- **Pagination**: Only loads 25 records per request
- **Eager Loading**: Prevents N+1 queries with deep includes
- **Index Hints**: Queries leverage database indexes on weight and created_at
- **Limit Results**: Never loads entire ranked_lists table
- **Selective Associations**: Only loads artists, not images (leaner queries than albums)

## Future Enhancements
- Add filtering by date ranges or list metadata
- Support user-created ranking configurations
- Add caching for frequently accessed lists
- Implement list search functionality
- Add export functionality (CSV, JSON)
- Consider eager loading album artwork if songs should display cover art

## Comparison with Albums Controller

| Feature | Songs Controller | Albums Controller |
|---------|-----------------|-------------------|
| Ranking Config Class | `Music::Songs::RankingConfiguration` | `Music::Albums::RankingConfiguration` |
| List STI Type | `Music::Songs::List` | `Music::Albums::List` |
| Eager Load Images | No | Yes (`primary_image`) |
| Route Prefix | `music/songs/lists` | `music/albums/lists` |
| Named Routes | `music_songs_lists_path` | `music_albums_lists_path` |
| Pagination Limit | 25 per page | 25 per page |
| Sort Options | weight, created_at | weight, created_at |

## Related Documentation
- [Music::Albums::ListsController](../albums/lists_controller.md) - Parallel controller for albums
- [Music::ListsController](../lists_controller.md) - Overview controller for all music lists
- [RankedList Model](../../../models/ranked_list.md)
- [RankingConfiguration Model](../../../models/ranking_configuration.md)
- [Music::Songs::List Model](../../../models/music/songs/list.md)
- [Music::Song Model](../../../models/music/song.md)

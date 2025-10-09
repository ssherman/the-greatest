# Music::ListsController

## Summary
Overview controller for music lists that displays top-ranked album lists and song lists on a single page. Serves as the landing page for the music lists section of the application.

## Purpose
Provides a consolidated view of the highest-weighted lists for both albums and songs in the music domain. This controller aggregates data from two separate ranking configurations to give users a quick overview of the most influential music lists in the system.

## Actions

### `index`
Displays the top 10 album lists and top 10 song lists ordered by weight.

**Query Strategy:**
- Fetches from two separate ranking configurations (albums and songs)
- Joins with the `lists` table to filter by STI type
- Includes `list_items` for efficient display
- Orders by `weight` descending (highest influence first)
- Limits to 10 results per category

**Instance Variables Set:**
- `@albums_ranked_lists` - Top 10 weighted album lists (Array of RankedList)
- `@songs_ranked_lists` - Top 10 weighted song lists (Array of RankedList)
- `@albums_ranking_configuration` - The primary albums ranking configuration
- `@songs_ranking_configuration` - The primary songs ranking configuration

**SQL Joins:**
```ruby
# Albums query
@albums_ranking_configuration.ranked_lists
  .joins(:list)
  .where(lists: { type: "Music::Albums::List" })
  .includes(list: :list_items)
  .order(weight: :desc)
  .limit(10)

# Songs query (similar structure)
```

## Routing

**Routes:**
```ruby
# config/routes.rb
get "lists", to: "music/lists#index", as: :music_lists
```

**URL Patterns:**
- `/music/lists` - Main music lists overview page

**Named Routes:**
- `music_lists_path` - Helper for the index action

## Configuration

### Layout
Uses `music/application` layout for consistent music domain styling.

### Callbacks
- `before_action :load_ranking_configurations` - Loads both primary ranking configurations before any action

## Private Methods

### `load_ranking_configurations`
Loads the default primary ranking configurations for both albums and songs.

**Implementation:**
```ruby
def load_ranking_configurations
  @albums_ranking_configuration = Music::Albums::RankingConfiguration.default_primary
  @songs_ranking_configuration = Music::Songs::RankingConfiguration.default_primary
end
```

**Purpose:**
- Ensures both ranking configurations are available in instance variables
- Uses `default_primary` scope to get the main ranking configuration for each media type
- Called via `before_action` so configurations are available for all actions

## Dependencies

### Models
- `Music::Albums::RankingConfiguration` - Configuration for album ranking algorithms
- `Music::Songs::RankingConfiguration` - Configuration for song ranking algorithms
- `RankedList` - Join model between lists and ranking configurations
- `Music::Albums::List` - Album-specific list model (STI)
- `Music::Songs::List` - Song-specific list model (STI)
- `ListItem` - Items within each list

### Concerns
None - inherits standard Rails controller functionality from ApplicationController

### External Dependencies
None - pure Rails application logic

## Related Controllers
- `Music::Albums::ListsController` - Detailed album lists browsing and individual list display
- `Music::Songs::ListsController` - Detailed song lists browsing and individual list display

## Views
- `app/views/music/lists/index.html.erb` - Main overview page template

## Usage Examples

### Accessing the Music Lists Overview
```ruby
# In routes
music_lists_path  # => "/music/lists"

# In controller
redirect_to music_lists_path
```

### Data Available in Views
```erb
<!-- In index.html.erb -->
<% @albums_ranked_lists.each do |ranked_list| %>
  <%= ranked_list.list.name %>
  <%= ranked_list.weight %>
  <%= ranked_list.list.list_items.count %>
<% end %>

<% @songs_ranked_lists.each do |ranked_list| %>
  <%= ranked_list.list.name %>
  <%= ranked_list.weight %>
<% end %>
```

## Design Notes

### Why Separate Ranking Configurations?
Albums and songs use separate ranking configurations because:
- They may have different algorithm parameters (exponent, bonus pool, penalties)
- They rank different types of items (Album vs Song models)
- They use different STI list types
- They may have different quality thresholds and weighting strategies

### Performance Considerations
- **Limit to 10**: Only fetches top 10 lists per category to keep page load fast
- **Eager Loading**: Uses `includes(list: :list_items)` to prevent N+1 queries
- **Pre-sorted**: Relies on database-level sorting by weight (indexed column)
- **No Pagination**: Deliberately limited to 10 items, no pagination needed

### Weight Ordering
Lists are ordered by their weight in the ranking configuration:
- Higher weight = more influence on the overall ranking
- Weight is calculated based on list quality metrics (voter count, recency, etc.)
- Null weights are considered lowest priority

## Future Enhancements
- Add ability to switch between different ranking configurations via params
- Support filtering by date ranges or list creation time
- Add pagination if the limit of 10 becomes insufficient
- Cache the ranking configuration lookups for performance

## Related Documentation
- [RankedList Model](../../models/ranked_list.md)
- [RankingConfiguration Model](../../models/ranking_configuration.md)
- [Music::Albums::ListsController](music/albums/lists_controller.md)
- [Music::Songs::ListsController](music/songs/lists_controller.md)

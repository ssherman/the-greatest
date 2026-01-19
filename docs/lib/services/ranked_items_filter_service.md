# Services::RankedItemsFilterService

## Summary
Service object for applying filters to ranked item queries. Designed to be extensible for future filter types (genre, etc.). Handles open-ended ranges for "since" and "through" filtering.

## Public Methods

### `#initialize(base_query, table_name:)`
Creates a new filter service instance.

**Parameters:**
- `base_query` (ActiveRecord::Relation) - The base query to filter
- `table_name` (String) - The table name for qualified column references (e.g., "music_albums")

**Example:**
```ruby
service = Services::RankedItemsFilterService.new(ranked_items_query, table_name: "music_albums")
```

### `#apply_year_filter(year_filter)`
Applies a year filter to the base query.

**Parameters:**
- `year_filter` (Filters::YearFilter::Result|nil) - The parsed year filter

**Returns:** `ActiveRecord::Relation` - filtered or original query

**Behavior:**
- Returns base query unchanged if `year_filter` is nil
- Open start (`:through`): `WHERE release_year <= end_year`
- Open end (`:since`): `WHERE release_year >= start_year`
- Closed range: `WHERE release_year BETWEEN start_year AND end_year`

**Example:**
```ruby
# Decade filter
filter = Filters::YearFilter.parse("1990s")
service.apply_year_filter(filter)
# => WHERE music_albums.release_year BETWEEN 1990 AND 1999

# Since filter (open-ended)
filter = Filters::YearFilter.parse("1980", mode: "since")
service.apply_year_filter(filter)
# => WHERE music_albums.release_year >= 1980

# Through filter (open-ended)
filter = Filters::YearFilter.parse("1970", mode: "through")
service.apply_year_filter(filter)
# => WHERE music_albums.release_year <= 1970
```

## Usage Pattern

Used in ranked item controllers to filter results by year:

```ruby
# reference only - from Music::Albums::RankedItemsController
def index
  parse_year_filter
  items = RankedItem.for_albums.includes(:album)

  if @year_filter
    service = ::Services::RankedItemsFilterService.new(items, table_name: "music_albums")
    items = service.apply_year_filter(@year_filter)
  end

  @pagy, @ranked_items = pagy(items)
end
```

## Design Notes

- Uses qualified column names (`table_name.release_year`) to work with JOINed queries
- Service pattern allows for future filter methods (e.g., `apply_genre_filter`)
- Stateless after initialization; can chain multiple filters

## Dependencies
- Expects `Filters::YearFilter::Result` struct from `Filters::YearFilter`

## Related Files
- `app/lib/filters/year_filter.rb` - parses year parameters into Result struct
- `app/controllers/music/albums/ranked_items_controller.rb` - uses this service
- `app/controllers/music/songs/ranked_items_controller.rb` - uses this service

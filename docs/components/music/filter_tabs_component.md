# Music::FilterTabsComponent

## Summary
ViewComponent that renders a horizontal tab bar for filtering albums/songs by decade, with a custom year range modal. Used on `/albums` and `/songs` index pages.

## Location
`app/components/music/filter_tabs_component.rb`

## Initialization

### Parameters
- `item_type` (String) - The type of items being filtered ("albums" or "songs")
- `base_path` (String) - The base URL path for generating filter links (e.g., "/albums")
- `year_filter` (Filters::YearFilter::Result or nil) - The current year filter, if any

### Example Usage
```erb
<%= render Music::FilterTabsComponent.new(
  item_type: "albums",
  base_path: albums_path,
  year_filter: @year_filter
) %>
```

## Features

### Tab Bar
- Displays tabs: All Time, 1960s, 1970s, 1980s, 1990s, 2000s, 2010s, 2020s, Custom
- Uses DaisyUI `tabs-boxed` styling with rounded container
- Wraps to multiple rows on mobile (flex-wrap)
- Highlights active tab based on current `year_filter`

### Active State Logic
- **All Time**: Active when `year_filter` is nil
- **Decade tabs**: Active when `year_filter.type == :decade` and display matches
- **Custom**: Active when `year_filter.type` is `:range`, `:single`, `:since`, or `:through`

### Custom Year Range Modal
- Two optional number inputs: "From Year" and "To Year"
- Uses `year-range-modal` Stimulus controller for validation and URL building
- Supports four URL patterns:
  - Only From → `/albums/since/{year}`
  - Only To → `/albums/through/{year}`
  - Both same → `/albums/{year}`
  - Both different → `/albums/{from}-{to}`

## Constants
- `DECADES` - Array of decade strings: `%w[1960s 1970s 1980s 1990s 2000s 2010s 2020s]`

## Private Methods

### `#decades`
Returns the DECADES constant.

### `#all_time_active?`
Returns true if no year filter is applied.

### `#decade_active?(decade)`
Returns true if the current filter matches the given decade.

### `#custom_active?`
Returns true if the current filter is a range, single year, since, or through type.

### `#tab_class(active:)`
Returns CSS classes for a tab. Includes `tab whitespace-nowrap` plus `tab-active` if active.

### `#decade_path(decade)`
Builds the URL path for a decade filter (e.g., "/albums/1990s").

### `#modal_id`
Returns unique modal ID based on item_type (e.g., "year_filter_modal_albums").

## Dependencies
- DaisyUI for tabs-boxed styling
- `year-range-modal` Stimulus controller for modal functionality
- `Filters::YearFilter` for parsing year parameters

## Related Files
- `app/components/music/filter_tabs_component.html.erb` - Template
- `app/javascript/controllers/year_range_modal_controller.js` - Modal logic
- `app/lib/filters/year_filter.rb` - Year filter parsing
- `test/components/music/filter_tabs_component_test.rb` - Tests

# Music::RankedItemsHelper

## Summary
Shared helper module for generating SEO-friendly titles and descriptions based on year filters. Used by album and song ranked items views.

## Public Methods

### `#year_title_phrase(year_filter, item_type)`
Generates an SEO page title for year-filtered lists.

**Parameters:**
- `year_filter` (Filters::YearFilter::Result) - The parsed year filter
- `item_type` (String) - "Albums" or "Songs"

**Returns:** `String` - formatted title phrase

**Examples:**
```ruby
year_title_phrase(decade_filter, "Albums")  # => "Greatest Albums of the 1990s"
year_title_phrase(range_filter, "Songs")    # => "Greatest Songs from 1980 to 2000"
year_title_phrase(single_filter, "Albums")  # => "Greatest Albums of 1994"
year_title_phrase(since_filter, "Albums")   # => "Greatest Albums Since 1980"
year_title_phrase(through_filter, "Songs")  # => "Greatest Songs Through 1970"
```

### `#year_description_phrase(year_filter)`
Generates a phrase for meta descriptions.

**Parameters:**
- `year_filter` (Filters::YearFilter::Result) - The parsed year filter

**Returns:** `String` - formatted description phrase (lowercase, no subject)

**Examples:**
```ruby
year_description_phrase(decade_filter)  # => "of the 1990s"
year_description_phrase(range_filter)   # => "from 1980 to 2000"
year_description_phrase(single_filter)  # => "from 1994"
year_description_phrase(since_filter)   # => "since 1980"
year_description_phrase(through_filter) # => "through 1970"
```

## Usage Pattern

Included in album and song ranked items helpers, used in views:

```erb
<% if @year_filter %>
  <% content_for :page_title do %>
    <%= year_title_phrase(@year_filter, "Albums") %>
  <% end %>
  <% content_for :meta_description do %>
    Browse the greatest albums <%= year_description_phrase(@year_filter) %>, ranked by critics.
  <% end %>
<% end %>
```

## Filter Type Mapping

| Type | Title Format | Description Format |
|------|--------------|-------------------|
| `:decade` | "Greatest X of the 1990s" | "of the 1990s" |
| `:range` | "Greatest X from 1980 to 2000" | "from 1980 to 2000" |
| `:single` | "Greatest X of 1994" | "from 1994" |
| `:since` | "Greatest X Since 1980" | "since 1980" |
| `:through` | "Greatest X Through 1970" | "through 1970" |

## Dependencies
- Expects `Filters::YearFilter::Result` struct with `type`, `display`, `start_year`, `end_year`

## Related Files
- `app/helpers/music/albums/ranked_items_helper.rb` - includes this module
- `app/helpers/music/songs/ranked_items_helper.rb` - includes this module
- `app/lib/filters/year_filter.rb` - provides the Result struct

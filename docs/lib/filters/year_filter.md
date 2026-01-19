# Filters::YearFilter

## Summary
Query object for parsing year filter parameters from URLs into structured Result objects. Supports decades (1990s), ranges (1980-2000), single years (1994), and open-ended ranges (since/through).

## Constants
- `DECADE_PATTERN` - `/^(\d{4})s$/` - matches "1990s"
- `RANGE_PATTERN` - `/^(\d{4})-(\d{4})$/` - matches "1980-2000"
- `SINGLE_PATTERN` - `/^(\d{4})$/` - matches "1994"

## Structs

### `Result`
Struct returned by `parse` with keyword arguments:
- `start_year` (Integer|nil) - Start of range (nil for `:through` type)
- `end_year` (Integer|nil) - End of range (nil for `:since` type)
- `display` (String) - Original parameter value for display
- `type` (Symbol) - One of `:decade`, `:range`, `:single`, `:since`, `:through`

## Public Methods

### `.parse(param, mode: nil)`
Parses a year parameter string into a Result struct.

**Parameters:**
- `param` (String) - The year parameter from the URL
- `mode` (String|nil) - Optional mode: `"since"` or `"through"` for open-ended ranges

**Returns:** `Result` struct or `nil` if param is blank

**Raises:** `ArgumentError` for invalid formats or reversed ranges

**Examples:**
```ruby
Filters::YearFilter.parse("1990s")
# => #<Result start_year=1990, end_year=1999, display="1990s", type=:decade>

Filters::YearFilter.parse("1980-2000")
# => #<Result start_year=1980, end_year=2000, display="1980-2000", type=:range>

Filters::YearFilter.parse("1994")
# => #<Result start_year=1994, end_year=1994, display="1994", type=:single>

Filters::YearFilter.parse("1980", mode: "since")
# => #<Result start_year=1980, end_year=nil, display="1980", type=:since>

Filters::YearFilter.parse("1970", mode: "through")
# => #<Result start_year=nil, end_year=1970, display="1970", type=:through>

Filters::YearFilter.parse("2000-1980")
# => raises ArgumentError
```

## Usage Pattern

Called from controllers via the shared `parse_year_filter` method in `Music::RankedItemsController`:

```ruby
# reference only
def parse_year_filter
  return unless params[:year].present?
  @year_filter = ::Filters::YearFilter.parse(params[:year], mode: params[:year_mode])
rescue ArgumentError
  raise ActionController::RoutingError, "Not Found"
end
```

## Dependencies
- None (pure Ruby)

## Related Files
- `app/lib/services/ranked_items_filter_service.rb` - applies filter to queries
- `app/helpers/music/ranked_items_helper.rb` - generates SEO titles from Result
- `app/controllers/music/ranked_items_controller.rb` - shared parse method

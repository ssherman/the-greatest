# ApplicationHelper

## Summary
Global view helper module providing utility methods available across all views in the application. Includes pagination helpers from Pagy and custom formatting methods.

**Location**: `app/helpers/application_helper.rb`

## Included Modules

### `Pagy::Frontend`
Provides pagination helper methods from the Pagy gem:
- `pagy_nav` - Pagination navigation links
- `pagy_info` - Pagination info text ("Showing 1-25 of 100 items")
- `pagy_url_for` - URL generation for pagination links

## Public Methods

### `#format_duration(seconds)`
Formats duration in seconds to human-readable time string.

**Parameters**:
- `seconds` (Integer or nil) - Duration in seconds

**Returns**:
- `String` - Formatted duration
  - `"—"` if seconds is nil or zero
  - `"M:SS"` format for durations under 1 hour (e.g., "3:45")
  - `"H:MM:SS"` format for durations 1 hour or more (e.g., "1:23:45")

**Examples**:
```ruby
format_duration(nil)      # => "—"
format_duration(0)        # => "—"
format_duration(45)       # => "0:45"
format_duration(125)      # => "2:05"
format_duration(3665)     # => "1:01:05"
format_duration(7385)     # => "2:03:05"
```

**Use Cases**:
- Song duration display in admin and public views
- Track duration in release tracklists
- Podcast episode durations
- Video length display

**Implementation Details**:
- Zero-pads minutes and seconds to 2 digits
- Hours displayed without padding
- Uses integer division and modulo for time component extraction

**Edge Cases**:
- Negative values: Not validated, will produce unexpected output
- Non-integer values: Implicitly converted via integer division
- Very large values: No upper limit, will format correctly

## Usage in Views

### Admin Views
```erb
<!-- Song show page -->
<p>Duration: <%= format_duration(@song.duration_secs) %></p>

<!-- Songs table -->
<td><%= format_duration(song.duration_secs) %></td>
```

### Public Views
```erb
<!-- Track listing -->
<span class="duration"><%= format_duration(track.duration_secs) %></span>
```

## Testing
**Test Location**: `test/helpers/application_helper_test.rb`
**Test Coverage**: 4 tests
- Nil/zero handling
- Short duration (< 1 hour)
- Medium duration (1-2 hours)
- Long duration (> 2 hours)

## Design Decisions

### Helper Location
**Decision**: Placed in `ApplicationHelper` rather than `Admin::MusicHelper` or domain-specific helper

**Rationale**:
- Universal utility applicable across all domains (music, books, movies, podcasts)
- Used in both admin and public views
- Simple, stateless formatting with no domain-specific logic
- Follows Rails convention of global helpers in ApplicationHelper

**Alternative Considered**: `Admin::MusicHelper` - Rejected as too narrow in scope

### Em Dash for Missing Data
Uses em dash (`"—"`) instead of empty string, "N/A", or nil

**Rationale**:
- Visual indicator that data is missing vs accidentally blank
- Consistent with duration being optional field
- Better UX than empty cell in tables

## Related Documentation
- **Usage**: `docs/controllers/admin/music/songs_controller.md` - Primary consumer
- **Model**: `docs/models/music/song.md` - duration_secs attribute
- **Implementation Task**: `docs/todos/completed/075-custom-admin-phase-4-songs.md`

## Future Enhancements
- Localization support for different time formats
- Validation/warning for negative durations
- Configurable formatting options (e.g., always show hours)
- Support for fractional seconds (currently truncated)

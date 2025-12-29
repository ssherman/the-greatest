# Admin::Music::Albums::Wizard::ReviewStepComponent

## Summary
ViewComponent for the review step of the Albums List Wizard. Displays a filterable table of list items with statistics cards and per-row action menus. Uses CSS-based filtering for O(1) performance with large lists.

## Initialization

```ruby
Admin::Music::Albums::Wizard::ReviewStepComponent.new(
  list: Music::Albums::List,
  items: Array<ListItem>,
  total_count: Integer,
  valid_count: Integer,
  invalid_count: Integer,
  missing_count: Integer
)
```

### Parameters
- `list` (Music::Albums::List) - The parent list record (required)
- `items` (Array) - Array of ListItem records to display (default: [])
- `total_count` (Integer) - Total number of items (default: 0)
- `valid_count` (Integer) - Number of verified items (default: 0)
- `invalid_count` (Integer) - Number of AI-flagged invalid items (default: 0)
- `missing_count` (Integer) - Number of items without matches (default: 0)

## Public Methods

### item_status(item)
Determines the status of an item for filtering.
- **Parameters**: `item` (ListItem)
- **Returns**: String - "valid", "invalid", or "missing"
- **Logic**:
  - "valid" if `item.verified?`
  - "invalid" if `item.metadata["ai_match_invalid"]`
  - "missing" otherwise

### status_badge_class(status)
Returns CSS classes for status badge.
- **Parameters**: `status` (String)
- **Returns**: String - Badge CSS classes (e.g., "badge badge-success badge-sm")

### status_badge_icon(status)
Returns SVG icon for status badge.
- **Parameters**: `status` (String)
- **Returns**: String (html_safe) - Checkmark, X, or dash icon

### row_background_class(status)
Returns CSS class for row background.
- **Parameters**: `status` (String)
- **Returns**: String - "bg-error/10", "bg-base-200", or ""

### original_title(item)
Extracts original title from item metadata.
- **Returns**: String - Title or "Unknown Title"

### original_artists(item)
Extracts original artists from item metadata.
- **Returns**: String - Comma-joined artists or "Unknown Artist"

### matched_title(item)
Gets matched album title from listable or metadata.
- **Returns**: String or nil
- **Priority**: listable.title > mb_release_group_name > album_name

### matched_artists(item)
Gets matched artists from listable or metadata.
- **Returns**: String or nil
- **Priority**: listable.artists > mb_artist_names > opensearch_artist_names

### source_badge(item)
Returns source badge information.
- **Returns**: Hash with `:text`, `:class`, `:title` keys
- **Sources**: "OS" (OpenSearch), "MB" (MusicBrainz), "Manual", or "-"

### percentage(count)
Calculates percentage of total.
- **Returns**: Float - Percentage rounded to 1 decimal

### verify_path(item)
Returns route path for verify action.

### modal_path(item, modal_type)
Returns route path for modal action.

## Template Structure

### Stats Cards
DaisyUI stats component with ID `review_stats_#{list.id}` for Turbo Stream updates.

### Filter Bar
Select dropdown with options: All, Valid Only, Invalid Only, Missing Only.
Connected to `review_filter_controller` Stimulus controller.

### CSS-Based Filtering
Uses data attributes and CSS rules for O(1) filtering:
```css
[data-filter="valid"] tr[data-status]:not([data-status="valid"]) {
  display: none;
}
```

### Item Table
Table with columns: Status, #, Original, Matched, Source, Actions.
Each row has:
- `id="item_row_#{item.id}"` for Turbo Stream targeting
- `data-status` for CSS filtering
- Popover menu with action links

### Shared Modal
Renders `SharedModalComponent` for on-demand modal loading.

## Stimulus Controller
Uses `review_filter_controller.js` with:
- Targets: `container`, `filter`, `count`
- Values: `totalCount`, `validCount`, `invalidCount`, `missingCount`
- MutationObserver for automatic recount on Turbo Stream updates

## Dependencies
- `Admin::Music::Albums::Wizard::SharedModalComponent`
- `review_filter_controller.js` (shared with songs)

## Related Files
- Template: `app/components/admin/music/albums/wizard/review_step_component.html.erb`
- Controller: `app/controllers/admin/music/albums/list_items_actions_controller.rb`
- Helper: `app/helpers/admin/music/albums/list_wizard_helper.rb`

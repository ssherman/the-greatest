# Admin::Music::Wizard::ItemRowComponent

## Summary
Base ViewComponent for wizard review step item rows. Renders a single list item as a table row with status badge, original/matched data, source badge, and action menu. Uses abstract method pattern - subclasses provide domain-specific configuration.

This is a base class that should not be instantiated directly. Use the domain-specific subclasses:
- `Admin::Music::Songs::Wizard::ItemRowComponent`
- `Admin::Music::Albums::Wizard::ItemRowComponent`

## Initialization

```ruby
Admin::Music::Songs::Wizard::ItemRowComponent.new(item: ListItem)
Admin::Music::Albums::Wizard::ItemRowComponent.new(item: ListItem)
```

### Parameters
- `item` (ListItem) - The list item to render (required)

## Abstract Methods (Subclasses Must Implement)

### matched_title_key
Returns the metadata key for matched title.
- **Songs**: `"mb_recording_name"`
- **Albums**: `"mb_release_group_name"`

### matched_name_fallback_key
Returns the fallback metadata key for name.
- **Songs**: `"song_name"`
- **Albums**: `"album_name"`

### matched_artists_fallback_keys
Returns array of fallback metadata keys for artists.
- **Songs**: `["mb_artist_names"]`
- **Albums**: `["mb_artist_names", "opensearch_artist_names"]`

### supports_manual_link?
Returns whether to show manual_link badge option.
- **Songs**: `false`
- **Albums**: `true`

### menu_items
Returns array of menu item configurations.
- **Returns**: Array of Hashes with keys: `:type`, `:text`, `:modal_type` (for links), `:css_class`
- **Types**: `:verify`, `:link`, `:delete`

### modal_frame_id
Returns the Turbo Frame ID for modal loading.
- **Returns**: String (SharedModalComponent::FRAME_ID constant)

### verify_item_path
Returns route path for verify action.

### modal_item_path(modal_type)
Returns route path for modal action.
- **Parameters**: `modal_type` (Symbol) - e.g., `:edit_metadata`, `:link_song`

### destroy_item_path
Returns route path for destroy action.

## Private Methods (Shared Logic)

### item_status
Determines the status of the item for filtering and display.
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

### original_title
Extracts original title from item metadata.
- **Returns**: String - Title or "Unknown Title"

### original_artists
Extracts original artists from item metadata.
- **Returns**: String - Comma-joined artists or "Unknown Artist"

### matched_title
Gets matched title from listable or metadata.
- **Returns**: String or nil
- **Priority**: listable.title > matched_title_key > matched_name_fallback_key

### matched_artists
Gets matched artists from listable or metadata.
- **Returns**: String or nil
- **Priority**: listable.artists > matched_artists_fallback_keys values

### source_badge
Returns source badge information.
- **Returns**: Hash with `:text`, `:css_class`, `:title` keys
- **Sources**: "OS" (OpenSearch with score), "MB" (MusicBrainz), "Manual" (if supported), or "-"

### popover_menu_id
Returns the DOM ID for the popover menu element.
- **Returns**: String - `"item_menu_#{item.id}"`

### popover_close_js
Returns JavaScript code to close the popover menu.
- **Returns**: String - `"document.getElementById('item_menu_123').hidePopover();"`

### Icon Methods
- `icon_check` - SVG checkmark icon (h-3 w-3)
- `icon_x` - SVG X icon (h-3 w-3)
- `icon_dash` - SVG dash icon (h-3 w-3)
- `icon_dots_vertical` - SVG vertical dots icon (h-4 w-4)

## Template Structure

### Table Row
```html
<tr id="item_row_{id}" class="{background}" data-status="{status}" data-item-id="{id}">
```

### Columns
1. **Status** - Badge with icon
2. **#** - Item position
3. **Original** - Title and artists from metadata
4. **Matched** - Linked entity or MusicBrainz match
5. **Source** - OS/MB/Manual/-
6. **Actions** - Popover menu

### Action Menu
Rendered from `menu_items` configuration array:
- `:verify` - Button for verify action (hidden if already verified)
- `:link` - Link to modal action
- `:delete` - Button for destroy action (with confirmation, separated by divider)

## Usage

### In ReviewStepComponent Template
```erb
<% items.each do |item| %>
  <%= render(Admin::Music::Songs::Wizard::ItemRowComponent.new(item: item)) %>
<% end %>
```

### In Turbo Stream Partial
```erb
<%# app/views/admin/music/songs/list_items_actions/_item_row.html.erb %>
<%= render(Admin::Music::Songs::Wizard::ItemRowComponent.new(item: item)) %>
```

## Dependencies
- Domain-specific `SharedModalComponent` for modal frame ID constant
- Rails route helpers for action paths
- ListItem model with `verified?`, `metadata`, `listable`, `list_id`, `position` attributes

## Related Files
- Template: `app/components/admin/music/wizard/item_row_component.html.erb`
- Songs subclass: `app/components/admin/music/songs/wizard/item_row_component.rb`
- Albums subclass: `app/components/admin/music/albums/wizard/item_row_component.rb`
- Songs partial: `app/views/admin/music/songs/list_items_actions/_item_row.html.erb`
- Albums partial: `app/views/admin/music/albums/list_items_actions/_item_row.html.erb`

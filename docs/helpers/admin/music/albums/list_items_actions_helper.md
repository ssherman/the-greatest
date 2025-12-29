# Admin::Music::Albums::ListItemsActionsHelper

## Summary
Helper module providing utility methods for the albums list items actions modal partials. Provides item labeling, JSON formatting, and MusicBrainz availability checking.

## Public Methods

### item_label(item)
Generates a human-readable label for a list item.
- **Parameters**: `item` (ListItem)
- **Returns**: String - Format: `"#1 - \"Album Title\" by Artist Name"`
- **Usage**: Display in modal headers to identify the item being edited

### formatted_metadata(item)
Pretty-prints item metadata as JSON.
- **Parameters**: `item` (ListItem)
- **Returns**: String - Formatted JSON string
- **Usage**: Pre-populate the metadata editor textarea

### musicbrainz_available?(item)
Checks if MusicBrainz search is available for the item.
- **Parameters**: `item` (ListItem)
- **Returns**: Boolean - True if `mb_artist_ids` array is non-empty
- **Usage**: Conditionally show MusicBrainz search form vs warning message

## Usage

These helpers are used in the modal partial templates:

```erb
<%# In _edit_metadata.html.erb %>
<p class="text-sm"><%= item_label(item) %></p>
<textarea><%= formatted_metadata(item) %></textarea>

<%# In _search_musicbrainz_releases.html.erb %>
<% if musicbrainz_available?(item) %>
  <%# Show search form %>
<% else %>
  <%# Show warning about needing artist match first %>
<% end %>
```

## Related Files
- Modal partials: `app/views/admin/music/albums/list_items_actions/modals/`
- Controller: `app/controllers/admin/music/albums/list_items_actions_controller.rb`

# Admin::AddCategoryModalComponent

## Summary
Reusable ViewComponent that renders a modal dialog for adding categories to items (Artists, Albums, Songs). Works across all media types (Music, Books, Movies, Games) and is designed for Turbo Stream replacement to keep the UI synchronized with category changes.

## Inheritance
Inherits from `ViewComponent::Base`.

## Component Type
Generated with `--sidecar` option, template located at:
`app/components/admin/add_category_modal_component/add_category_modal_component.html.erb`

## Props

### `item` (required)
The item to which categories will be added.
- **Type**: Any categorizable item (Music::Artist, Music::Album, Music::Song, etc.)
- **Used For**:
  - Generating form submission URL
  - Determining search endpoint URL
  - Displaying item type context in UI

## Template Structure

### Container
Wrapped in `<div id="add_category_modal">` for Turbo Stream replacement.

### Modal Dialog
Uses DaisyUI modal component (`dialog.modal`) with ID `add_category_modal_dialog`.

### Form
- **Model**: `CategoryItem.new`
- **URL**: Dynamic based on item type (via `form_url` method)
- **Method**: POST
- **Stimulus Controller**: `modal-form` (auto-closes modal on success)
- **Data Attributes**:
  - `modal_form_modal_id_value: "add_category_modal_dialog"` - Links form to modal
  - `turbo_frame: "category_items_list"` - Targets Turbo Stream replacement

### Category Selection
- **Field**: Autocomplete component for `category_id`
- **Component**: `AutocompleteComponent`
- **URL**: Dynamic based on item type (via `search_url` method)
- **Placeholder**: "Search for category..."
- **Required**: Yes

### Actions
- **Cancel Button**: Closes modal without submission
- **Submit Button**: "Add Category" - submits form via Turbo Stream

## Public Methods

### `#form_url`
Returns the form submission URL based on item type.

**Implementation**:
```ruby
def form_url
  case @item.class.name
  when "Music::Artist"
    helpers.admin_artist_category_items_path(@item)
  when "Music::Album"
    helpers.admin_album_category_items_path(@item)
  when "Music::Song"
    helpers.admin_song_category_items_path(@item)
  # Future: when "Books::Book", "Movies::Movie", "Games::Game"
  end
end
```

**Returns**: String URL path

### `#search_url`
Returns the category search endpoint URL.

**Implementation**:
```ruby
def search_url
  # Currently only Music categories exist. When Books/Movies/Games are added,
  # this will need a case statement to route to domain-specific search endpoints.
  helpers.search_admin_categories_path
end
```

**Returns**: String URL path

**Note**: Currently returns Music categories search path. Will need expansion when other domains (Books, Movies, Games) are implemented.

### `#item_type_label`
Returns a human-readable label for the item type.
- **Returns**: String (e.g., "artist", "album", "song")
- **Usage**: Displayed in modal description text

## Turbo Stream Integration

### Replacement Target
The outer `<div id="add_category_modal">` serves as the replacement target when:
- A category is successfully added (refreshes component state)
- A category is removed (refreshes component state)

### Stimulus Controller
The `modal-form` Stimulus controller handles:
- Auto-closing modal on successful form submission
- Managing modal state
- Coordinating with Turbo Stream responses

## Usage Examples

### In Artist Show Page
```erb
<%= render Admin::AddCategoryModalComponent.new(item: @artist) %>
```

### In Album Show Page
```erb
<%= render Admin::AddCategoryModalComponent.new(item: @album) %>
```

### In Turbo Stream Response
```ruby
turbo_stream.replace(
  "add_category_modal",
  Admin::AddCategoryModalComponent.new(item: @item)
)
```

## UI Pattern

### Modal Trigger
The component only renders the modal dialog itself. The trigger button is typically placed elsewhere in the UI:
```erb
<button onclick="add_category_modal_dialog.showModal()">
  + Add Category
</button>
```

### Real-Time Updates
When a category is added/removed:
1. Controller creates/destroys CategoryItem record
2. Controller responds with Turbo Stream
3. Turbo Stream replaces `#add_category_modal` with fresh component
4. Modal auto-closes via Stimulus controller

## Cross-Domain Design
The component is intentionally domain-agnostic:
- Works with any categorizable item type
- Media type detection via `@item.class.name` pattern matching
- Search URL routed to appropriate domain's category search endpoint
- No hardcoded media-specific logic in component

## Dependencies
- `AutocompleteComponent` - For category search input
- DaisyUI CSS framework for modal styles
- Turbo for form submission and stream replacement
- Stimulus `modal-form` controller for auto-close behavior

## Related Components
- `Admin::CategoryItemsController` - Handles form submission and Turbo Stream responses
- `Admin::Music::CategoriesController#search` - Provides category autocomplete endpoint
- `CategoryItem` model - Validates category assignment

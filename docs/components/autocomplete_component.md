# AutocompleteComponent

## Summary
Global, reusable ViewComponent for autocomplete functionality. Integrates with autoComplete.js library (v10.2.9) via Stimulus controller. Can be used throughout the application for any autocomplete needs (admin, public features, list creation, etc.).

## Purpose
Provides search-as-you-type functionality for large datasets where traditional select dropdowns would be impractical (e.g., 2000+ artists, 3000+ albums).

## Parameters

### Required
- `name` (String) - Form field name (e.g., `"music_album_artist[artist_id]"`)
- `url` (String) - Endpoint URL for autocomplete search (e.g., `search_admin_artists_path`)

### Optional
- `placeholder` (String) - Input placeholder text. Default: `"Search..."`
- `value` (String|Integer) - Pre-selected value ID. Default: `nil`
- `selected_text` (String) - Display text for pre-selected value. Default: `nil`
- `display_key` (String) - JSON key for display text in results. Default: `"text"`
- `value_key` (String) - JSON key for value in results. Default: `"value"`
- `min_length` (Integer) - Minimum characters before search triggers. Default: `2`
- `debounce` (Integer) - Debounce delay in milliseconds. Default: `300`
- `required` (Boolean) - Whether field is required. Default: `false`
- `disabled` (Boolean) - Whether field is disabled. Default: `false`

## Usage Example

```erb
<%= render AutocompleteComponent.new(
  name: "music_album_artist[artist_id]",
  url: search_admin_artists_path,
  placeholder: "Search for artist...",
  required: true
) %>
```

## HTML Structure

Renders two inputs:
1. **Hidden field** - Stores selected ID value for form submission
2. **Visible search input** - User types here, displays selected text

Wrapped in `.autocomplete-container` div with `position: relative` to contain absolutely-positioned dropdown.

## Integration

Works with `autocomplete_controller.js` Stimulus controller which:
- Fetches results from configured URL
- Displays results in DaisyUI-styled dropdown
- Updates both hidden and visible fields on selection
- Handles keyboard navigation (WAI-ARIA compliant)
- Debounces requests and cancels in-flight requests

## Expected API Response Format

Endpoint should return JSON array:
```json
[
  {"value": 123, "text": "Artist Name"},
  {"value": 456, "text": "Another Artist"}
]
```

Keys can be customized via `display_key` and `value_key` parameters.

## Styling
Uses DaisyUI form components (`.form-control`, `.input`, `.label`). Dropdown styled with DaisyUI menu classes.

## Dependencies
- Stimulus controller: `autocomplete_controller.js`
- JavaScript library: autoComplete.js v10.2.9
- CSS framework: DaisyUI/Tailwind CSS

# year_range_modal_controller

## Summary
Stimulus controller that handles custom year range filtering. Validates year inputs, builds the appropriate URL based on which fields are filled, and navigates to the filtered page.

## Location
`app/javascript/controllers/year_range_modal_controller.js`

## Targets
- `fromYear` - Number input for the start year
- `toYear` - Number input for the end year
- `applyButton` - Submit button (disabled until valid input)
- `error` - Element to display validation errors

## Values
- `basePath` (String) - Base URL path for building filter URLs (e.g., "/albums" or "/songs")

## Actions

### `validate`
Called on input change. Validates the year inputs and enables/disables the Apply button.

**Validation Rules:**
- At least one field must be filled
- Years must be 4 digits (regex: `/^\d{4}$/`)
- If both filled, from year must be <= to year

### `apply`
Called when Apply button is clicked. Builds the URL and navigates to it.

## URL Building Logic

The `buildUrl()` method determines which URL pattern to use:

| From | To | Result URL |
|------|-----|------------|
| empty | empty | null (button disabled) |
| 1980 | empty | `{basePath}/since/1980` |
| empty | 2000 | `{basePath}/through/2000` |
| 1994 | 1994 | `{basePath}/1994` |
| 1980 | 2000 | `{basePath}/1980-2000` |

## Example Usage

```html
<div data-controller="year-range-modal"
     data-year-range-modal-base-path-value="/albums">
  <input type="number"
         data-year-range-modal-target="fromYear"
         data-action="input->year-range-modal#validate">
  <input type="number"
         data-year-range-modal-target="toYear"
         data-action="input->year-range-modal#validate">
  <p data-year-range-modal-target="error" class="hidden"></p>
  <button data-year-range-modal-target="applyButton"
          data-action="click->year-range-modal#apply"
          disabled>
    Apply
  </button>
</div>
```

## Error Messages
- "From year must be a 4-digit year"
- "To year must be a 4-digit year"
- "From year cannot be greater than To year"

## Related Files
- `app/components/music/filter_tabs_component.html.erb` - Uses this controller
- `app/lib/filters/year_filter.rb` - Server-side year parsing (mirrors URL logic)
- `config/routes.rb` - Defines the URL patterns this controller targets

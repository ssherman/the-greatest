# Admin::Music::Songs::Wizard::ReviewStepComponent

## Summary
ViewComponent for the review step of the Songs List Wizard. Displays statistics cards and a filterable table of list items. Uses CSS-based filtering for O(1) performance with large lists. Delegates individual row rendering to `ItemRowComponent`.

## Initialization

```ruby
Admin::Music::Songs::Wizard::ReviewStepComponent.new(
  list: Music::Songs::List,
  items: Array<ListItem>,
  total_count: Integer,
  valid_count: Integer,
  invalid_count: Integer,
  missing_count: Integer
)
```

### Parameters
- `list` (Music::Songs::List) - The parent list record (required)
- `items` (Array) - Array of ListItem records to display (default: [])
- `total_count` (Integer) - Total number of items (default: 0)
- `valid_count` (Integer) - Number of verified items (default: 0)
- `invalid_count` (Integer) - Number of AI-flagged invalid items (default: 0)
- `missing_count` (Integer) - Number of items without matches (default: 0)

## Public Methods

### percentage(count)
Calculates percentage of total.
- **Parameters**: `count` (Integer)
- **Returns**: Float - Percentage rounded to 1 decimal, or 0 if total is zero

## Template Structure

### Stats Cards
DaisyUI stats component with ID `review_stats_#{list.id}` for Turbo Stream updates.
Displays:
- Total Items
- Valid count (verified)
- Invalid count (AI-flagged)
- Missing count (no match)

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
Renders each item using `Admin::Music::Songs::Wizard::ItemRowComponent`:
```erb
<% items.each do |item| %>
  <%= render(Admin::Music::Songs::Wizard::ItemRowComponent.new(item: item)) %>
<% end %>
```

### Shared Modal
Renders `SharedModalComponent` for on-demand modal loading.

## Stimulus Controller
Uses `review_filter_controller.js` with:
- Targets: `container`, `filter`, `count`
- Values: `totalCount`, `validCount`, `invalidCount`, `missingCount`
- MutationObserver for automatic recount on Turbo Stream updates

## Dependencies
- `Admin::Music::Songs::Wizard::ItemRowComponent` - Renders individual item rows
- `Admin::Music::Songs::Wizard::SharedModalComponent` - Shared modal for actions
- `review_filter_controller.js` (shared with albums)

## Related Files
- Template: `app/components/admin/music/songs/wizard/review_step_component.html.erb`
- Item row component: `app/components/admin/music/songs/wizard/item_row_component.rb`
- Base item row: `app/components/admin/music/wizard/item_row_component.rb`
- Controller: `app/controllers/admin/music/songs/list_items_actions_controller.rb`
- Helper: `app/helpers/admin/music/songs/list_wizard_helper.rb`

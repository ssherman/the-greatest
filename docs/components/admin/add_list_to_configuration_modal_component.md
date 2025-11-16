# Admin::AddListToConfigurationModalComponent

## Summary
ViewComponent that renders a modal dialog for adding lists to ranking configurations. Filters available lists by media type compatibility and excludes already-added lists. Uses DaisyUI dialog element with Stimulus controller for auto-close behavior.

## Initialization
```ruby
Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration)
```

**Parameters**:
- `ranking_configuration` (RankingConfiguration) - The ranking configuration to add lists to

## Public Methods

### `available_lists`
Returns filtered ActiveRecord relation of lists available to add
- **Returns**: `ActiveRecord::Relation<List>`
- **Filters**:
  - Media type compatibility (matches ranking configuration type)
  - Status is `:active` or `:approved` only
  - Not already added to this configuration
- **Ordering**: By `created_at DESC` (newest first)

**Media Type Mapping**:
- `Books::RankingConfiguration` → `Books::List`
- `Movies::RankingConfiguration` → `Movies::List`
- `Games::RankingConfiguration` → `Games::List`
- `Music::Albums::RankingConfiguration` → `Music::Albums::List`
- `Music::Songs::RankingConfiguration` → `Music::Songs::List`
- Unknown types → `List.none`

**Example**:
```ruby
# For Music::Albums::RankingConfiguration
component.available_lists
# => Returns Music::Albums::List records that are approved/active and not already ranked
```

## Template Structure

### Modal Elements
- **Dialog ID**: `add_list_to_configuration_modal_dialog`
- **Component ID**: `add_list_to_configuration_modal` (for Turbo Stream replacement)
- **Modal Type**: DaisyUI `<dialog>` element

### Form
- **Action**: `admin_ranking_configuration_ranked_lists_path(@ranking_configuration)`
- **Method**: POST
- **Turbo**: `data-turbo-frame="ranked_lists_list"`
- **Stimulus**: `data-controller="modal-form"` (auto-close on success)

### List Selector
- **Field**: `ranked_list[list_id]`
- **Options**: Dropdown showing list name and source
- **Format**: `"[List Name] ([Source])"` or `"[List Name] (No source)"`
- **Empty State**: "All compatible lists already added" when no lists available

### Buttons
- **Submit**: "Add List" (primary button)
- **Cancel**: "Cancel" (ghost button, closes modal via `form.close()`)

## Turbo Stream Integration
After successful submission:
1. Flash message shows success
2. Ranked lists table updates with new list
3. **This component re-renders** with updated available_lists (newly added list excluded)
4. Modal auto-closes via Stimulus controller

## Display Logic

### List Name Format
Shows list name with source attribution:
```erb
<%= list.name %> (<%= list.source || 'No source' %>)
```

### Empty State
When `available_lists.none?`:
```erb
<option>All compatible lists already added</option>
```

## Media Type Validation
Relies on RankedList model validation for enforcement:
- Client-side: Dropdown only shows compatible lists
- Server-side: Model validates media type compatibility
- Error handling: Flash shows validation error if mismatch occurs

## Usage Example

In ranking configuration show page:
```erb
<!-- Render modal at bottom of page -->
<%= render Admin::AddListToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration) %>

<!-- Open modal via button -->
<button class="btn btn-primary btn-sm" onclick="add_list_to_configuration_modal_dialog.showModal()">
  + Add List
</button>
```

## Dependencies
- **Model**: `RankedList` - Join model with validations
- **Model**: `List` - Source lists
- **Model**: `RankingConfiguration` - Target configuration
- **Stimulus**: `modal-form` controller for auto-close
- **Turbo**: Turbo Streams for real-time updates
- **DaisyUI**: Dialog component styling

## Related Files
- **Controller**: `app/controllers/admin/ranked_lists_controller.rb`
- **Template**: `app/components/admin/add_list_to_configuration_modal_component/add_list_to_configuration_modal_component.html.erb`
- **Tests**: `test/components/admin/add_list_to_configuration_modal_component_test.rb`
- **Pattern Source**: `app/components/admin/add_penalty_to_configuration_modal_component.rb`
- **Stimulus Controller**: `app/javascript/controllers/modal_form_controller.js`

## Test Coverage
- Modal renders with form and list selector
- `available_lists` returns filtered lists by media type
- `available_lists` excludes already added lists
- `available_lists` only includes approved/active lists
- `available_lists` orders by created_at DESC
- Empty state shown when no lists available

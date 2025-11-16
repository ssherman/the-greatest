# Admin::EditPenaltyApplicationModalComponent

**Path**: `app/components/admin/edit_penalty_application_modal_component.rb`
**Template**: `app/components/admin/edit_penalty_application_modal_component/edit_penalty_application_modal_component.html.erb`

## Purpose

ViewComponent that renders a modal dialog for editing the value of an existing penalty application. Unlike the add modal, this component only allows changing the percentage value (0-100), not the penalty itself.

## Usage

```erb
<%= render Admin::EditPenaltyApplicationModalComponent.new(penalty_application: @penalty_application) %>
```

## Parameters

### `penalty_application` (required)

**Type**: `PenaltyApplication`
**Description**: The existing penalty application record to edit
**Associations**: Must have `penalty` and `ranking_configuration` associations loaded

## Public Methods

None - This is a simple component with no helper methods. All data comes from the `@penalty_application` parameter.

## Modal Structure

### Container

- **ID**: `edit_penalty_application_modal`
- **Purpose**: Wrapper for modal component

### Dialog Element

- **ID**: `edit_penalty_application_modal_dialog`
- **Type**: Native `<dialog>` element
- **Class**: `modal` (DaisyUI)
- **Open Trigger**: Automatically shown when view loads (via JavaScript in edit.html.erb)

### Form

**Action**: `admin_penalty_application_path(@penalty_application)`
**Method**: PATCH
**Stimulus Controller**: `modal-form`
**Modal ID Value**: `edit_penalty_application_modal_dialog`
**Turbo Frame Target**: `penalty_applications_list`

**Form Fields**:

1. **Penalty Name** (read-only display)
   - **Type**: Disabled text input
   - **Value**: `@penalty_application.penalty.name`
   - **Purpose**: Shows which penalty is being edited (cannot be changed)
   - **Help Text**: "Penalty cannot be changed"

2. **Value Input** (editable number field)
   - **Field**: `penalty_application[value]`
   - **Type**: Number input
   - **Min**: 0
   - **Max**: 100
   - **Step**: 1
   - **Placeholder**: "0-100"
   - **Pre-filled**: Current `@penalty_application.value`
   - **Required**: Yes
   - **Help Text**: "Penalty percentage (0-100)"

**Actions**:
- Cancel button: Closes modal via `edit_penalty_application_modal_dialog.close()`
- Submit button: "Update Penalty" (primary style)

## Stimulus Integration

**Controller**: `modal-form`
**Data Attributes**:
- `data-controller="modal-form"`
- `data-modal-form-modal-id-value="edit_penalty_application_modal_dialog"`
- `data-turbo-frame="penalty_applications_list"`

**Behavior**:
- Auto-closes modal on successful submission
- Keeps modal open on validation errors
- Does NOT refresh the modal itself (only the list)

## Turbo Stream Integration

**On Successful Update**:
The controller responds with 2 turbo stream replacements:
1. Flash message (success)
2. Penalty applications list (updated data with new value)

**Note**: Unlike the add modal, the edit modal does NOT refresh itself because:
- No dropdown state to update (penalty is fixed)
- Value field will have the submitted value if user wants to edit again

## UI/UX Notes

**Read-Only Penalty**:
The penalty cannot be changed after creation. This is enforced by:
1. Disabled input field showing penalty name
2. Strong parameters only permit `value` (not `penalty_id`)
3. UI help text explaining constraint

**Why No Penalty Change**:
- Changing the penalty would be semantically equivalent to delete + create
- Simpler UX: "To change penalty, remove this one and add a different one"
- Prevents accidental penalty swaps

**Accessibility**:
- Native `<dialog>` element for proper modal semantics
- Labels on all form fields
- Disabled field properly marked
- Help text for clarity
- Keyboard navigation supported

## Opening the Modal

Unlike the add modal (opened via button click), the edit modal is triggered differently:

**Method 1**: Direct link from index table
```erb
<%= link_to edit_admin_penalty_application_path(penalty_application),
    data: { turbo_frame: "_top" } do %>
  <svg><!-- edit icon --></svg>
<% end %>
```

**Method 2**: Auto-show via edit.html.erb
```erb
<%= render Admin::EditPenaltyApplicationModalComponent.new(penalty_application: @penalty_application) %>

<script>
  document.addEventListener('DOMContentLoaded', function() {
    const modal = document.getElementById('edit_penalty_application_modal_dialog');
    if (modal) {
      modal.showModal();
    }
  });
</script>
```

**Flow**:
1. User clicks edit icon in penalty applications table
2. GET /admin/penalty_applications/:id/edit (breaks out of turbo frame with `_top`)
3. Controller renders edit.html.erb (no layout)
4. View renders this component + auto-show script
5. Modal appears with current value pre-filled

## Related Components

**Add Component**: `Admin::AddPenaltyToConfigurationModalComponent`
**Key Differences**:
- Edit has read-only penalty display (add has dropdown)
- Edit only has value field editable (add has both penalty and value)
- Edit pre-fills current value (add has empty value)
- Edit sends PATCH (add sends POST)
- Edit has 2 turbo stream replacements (add has 3)

## Integration Points

**Triggered From**:
- Edit icon in `app/views/admin/penalty_applications/index.html.erb`

**Rendered In**:
- `app/views/admin/penalty_applications/edit.html.erb`

**Submits To**:
`Admin::PenaltyApplicationsController#update`

## Tests

**File**: `test/components/admin/edit_penalty_application_modal_component_test.rb`
**Coverage**: 4 tests
- Modal renders with form
- Shows penalty name as read-only
- Pre-fills current value
- Includes value input with correct attributes

## Example Workflow

```ruby
# 1. User viewing penalty applications table
# → Sees: "Low Voter Count | Global | Static | 75% | [Edit] [Delete]"

# 2. User clicks edit icon
# → GET /admin/penalty_applications/999/edit
# → Breaks out of turbo frame (data-turbo-frame="_top")

# 3. Controller responds with edit view
# → Renders EditPenaltyApplicationModalComponent
# → JavaScript auto-shows modal
# → Modal displays:
#   - "Penalty: Low Voter Count" (disabled input)
#   - "Value (%): [75]" (editable number input, pre-filled)

# 4. User changes value from 75 to 50 and submits
# → PATCH /admin/penalty_applications/999
# → Params: { penalty_application: { value: 50 } }

# 5. Success response (turbo stream)
# → Flash: "Penalty application updated successfully."
# → List updates showing: "Low Voter Count | Global | Static | 50%"
# → modal-form Stimulus controller auto-closes modal

# 6. Validation error example (value 150)
# → PATCH /admin/penalty_applications/999
# → Params: { penalty_application: { value: 150 } }
# → Response: 422 Unprocessable Entity
# → Flash: "Value must be less than or equal to 100"
# → Modal stays open for user to correct
```

## Design Decisions

**Why Separate Component** (vs. reusing add modal)?
1. Different form action (PATCH vs POST)
2. Different form fields (read-only penalty vs dropdown)
3. Different turbo stream responses (2 vs 3 replacements)
4. Clearer separation of concerns

**Why Pre-fill Value**?
- Most edit operations involve small adjustments (75 → 50)
- Seeing current value helps user make informed change
- Standard UX pattern for edit forms

**Why Disable Penalty Field**?
- Visual indicator that penalty cannot be changed
- Screen reader accessibility (announced as disabled)
- Prevents confusion vs. dropdown in add modal

## Implementation Notes

**Created**: 2025-11-15 (Phase 12)
**Pattern Source**: New pattern (list_penalties doesn't have edit functionality)
**Design Principle**: Minimal editable surface area - only expose what can/should change

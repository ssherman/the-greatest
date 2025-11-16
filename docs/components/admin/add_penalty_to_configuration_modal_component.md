# Admin::AddPenaltyToConfigurationModalComponent

**Path**: `app/components/admin/add_penalty_to_configuration_modal_component.rb`
**Template**: `app/components/admin/add_penalty_to_configuration_modal_component/add_penalty_to_configuration_modal_component.html.erb`

## Purpose

ViewComponent that renders a modal dialog for attaching penalties to ranking configurations with a configurable percentage value (0-100). This generic component works across all media types (Music, Books, Movies, Games) and filters available penalties based on media type compatibility.

## Usage

```erb
<%= render Admin::AddPenaltyToConfigurationModalComponent.new(ranking_configuration: @ranking_configuration) %>
```

## Parameters

### `ranking_configuration` (required)

**Type**: `RankingConfiguration` (STI base class or subclass)
**Description**: The ranking configuration to attach penalties to
**Valid Types**:
- `Music::Albums::RankingConfiguration`
- `Music::Songs::RankingConfiguration`
- `Books::RankingConfiguration` (future)
- `Movies::RankingConfiguration` (future)
- `Games::RankingConfiguration` (future)

**Note**: NOT used with `Music::Artists::RankingConfiguration` (artists use different calculation method)

## Public Methods

### `available_penalties`

Returns a filtered, ordered collection of penalties available for attachment to the ranking configuration.

**Filtering Logic**:
1. **Media Type Compatibility**: Only includes penalties where:
   - Type is `Global::Penalty` (works with any configuration), OR
   - Type matches configuration's media type (e.g., `Music::Penalty` for `Music::*::RankingConfiguration`)

2. **Exclusion**: Filters out penalties already applied to this configuration

3. **Ordering**: Alphabetical by penalty name

**Return Type**: `ActiveRecord::Relation<Penalty>`

**Example**:
```ruby
# For Music::Albums::RankingConfiguration
component.available_penalties
# => Returns Global penalties + Music penalties
# => Excludes Books, Movies, Games penalties
# => Excludes penalties already applied to this configuration
```

**Query**:
```ruby
media_type = @ranking_configuration.type.split("::").first # "Music", "Books", etc.

Penalty
  .where("type IN (?, ?)", "Global::Penalty", "#{media_type}::Penalty")
  .where.not(id: @ranking_configuration.penalties.pluck(:id))
  .order(:name)
```

## Modal Structure

### Container

- **ID**: `add_penalty_to_configuration_modal`
- **Purpose**: Wrapper for modal component

### Dialog Element

- **ID**: `add_penalty_to_configuration_modal_dialog`
- **Type**: Native `<dialog>` element
- **Class**: `modal` (DaisyUI)
- **Open Trigger**: `add_penalty_to_configuration_modal_dialog.showModal()`

### Form

**Action**: `admin_ranking_configuration_penalty_applications_path(@ranking_configuration)`
**Method**: POST
**Stimulus Controller**: `modal-form`
**Modal ID Value**: `add_penalty_to_configuration_modal_dialog`
**Turbo Frame Target**: `penalty_applications_list`

**Form Fields**:

1. **Penalty Selection** (dropdown)
   - **Field**: `penalty_application[penalty_id]`
   - **Type**: Select dropdown
   - **Options**: From `available_penalties` (id/name pairs)
   - **Prompt**: "Select a penalty..."
   - **Required**: Yes
   - **Help Text**: "Only compatible penalties shown (Global + [MediaType])"

2. **Value Input** (number field)
   - **Field**: `penalty_application[value]`
   - **Type**: Number input
   - **Min**: 0
   - **Max**: 100
   - **Step**: 1
   - **Placeholder**: "0-100"
   - **Required**: Yes
   - **Help Text**: "Penalty percentage (0-100)"

**Actions**:
- Cancel button: Closes modal via `add_penalty_to_configuration_modal_dialog.close()`
- Submit button: "Add Penalty" (primary style)

## Stimulus Integration

**Controller**: `modal-form`
**Data Attributes**:
- `data-controller="modal-form"`
- `data-modal-form-modal-id-value="add_penalty_to_configuration_modal_dialog"`
- `data-turbo-frame="penalty_applications_list"`

**Behavior**:
- Auto-closes modal on successful submission
- Keeps modal open on validation errors
- Refreshes modal content via turbo stream on success

## Turbo Stream Integration

**On Successful Create**:
The controller responds with 3 turbo stream replacements:
1. Flash message (success)
2. Penalty applications list (updated data)
3. **This modal component** (refreshed with updated available_penalties)

**Why Modal Refreshes**:
After attaching a penalty, the dropdown must exclude the newly attached penalty from `available_penalties`. The turbo stream replacement ensures the modal always shows the current state.

## UI/UX Notes

**Empty State**:
If `available_penalties` returns empty collection (all compatible penalties already applied):
- Dropdown will show only the prompt "Select a penalty..."
- User cannot submit (required field validation)
- Consider adding explanatory text: "All compatible penalties already applied"

**Accessibility**:
- Native `<dialog>` element for proper modal semantics
- Labels on all form fields
- Help text for clarity
- Keyboard navigation supported (Tab, Escape to close)

## Media Type Compatibility Examples

**For `Music::Albums::RankingConfiguration`**:
- ✅ Shows: Global::Penalty
- ✅ Shows: Music::Penalty
- ❌ Hides: Books::Penalty
- ❌ Hides: Movies::Penalty
- ❌ Hides: Games::Penalty

**For `Books::RankingConfiguration` (future)**:
- ✅ Shows: Global::Penalty
- ✅ Shows: Books::Penalty
- ❌ Hides: Music::Penalty
- ❌ Hides: Movies::Penalty
- ❌ Hides: Games::Penalty

## Related Components

**Similar Component**: `Admin::AttachPenaltyModalComponent` (for lists)
**Key Differences**:
1. Parent model: RankingConfiguration vs List
2. Has value input field (0-100) - list penalties don't have values
3. Works with all penalty types (static + dynamic) - list penalties only static
4. Different modal IDs and form action

**Edit Component**: `Admin::EditPenaltyApplicationModalComponent`
- Allows updating the value after creation
- Shows penalty name as read-only

## Integration Points

**Rendered In**:
- `app/views/admin/music/albums/ranking_configurations/show.html.erb`
- `app/views/admin/music/songs/ranking_configurations/show.html.erb`
- Future: Books/Movies/Games ranking configuration show pages

**Opened By**:
Button with `onclick="add_penalty_to_configuration_modal_dialog.showModal()"`

**Submits To**:
`Admin::PenaltyApplicationsController#create`

## Tests

**File**: `test/components/admin/add_penalty_to_configuration_modal_component_test.rb`
**Coverage**: 5 tests
- Modal renders with form
- Includes value input field with correct attributes
- `available_penalties` filters correctly
- `available_penalties` filters by media type
- `available_penalties` excludes already applied penalties

## Example Workflow

```ruby
# 1. User visits album ranking configuration show page
# → Modal component rendered at bottom of page (not visible)

# 2. User clicks "+ Add Penalty" button
add_penalty_to_configuration_modal_dialog.showModal()
# → Modal becomes visible
# → Dropdown populated via available_penalties method
# → Shows: "Low Voter Count (Global)", "Few Western Voters (Music)"
# → Hides: "Short Descriptions (Books)" - wrong media type
# → Hides: "Old List Age (Music)" - already applied

# 3. User selects "Low Voter Count" and enters value "75"
# → Form validation: penalty_id required, value 0-100

# 4. User submits form
# → POST /admin/ranking_configuration/123/penalty_applications
# → Params: { penalty_application: { penalty_id: 456, value: 75 } }

# 5. Success response (turbo stream)
# → Flash: "Penalty attached successfully."
# → List updates with new penalty application
# → Modal refreshes (Low Voter Count now excluded from dropdown)
# → modal-form Stimulus controller auto-closes modal
```

## Implementation Notes

**Created**: 2025-11-15 (Phase 12)
**Pattern Source**: `Admin::AttachPenaltyModalComponent` (Phase 11)
**Generic Design**: Works across all media types without modification

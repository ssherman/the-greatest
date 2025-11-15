# Admin::AttachPenaltyModalComponent

## Summary
Reusable ViewComponent that renders a modal dialog for attaching penalties to lists. Works across all media types (Music, Books, Movies, Games) and is designed for Turbo Stream replacement to keep the available penalties list current.

## Inheritance
Inherits from `ViewComponent::Base`.

## Component Type
Generated with `--sidecar` option, template located at:
`app/components/admin/attach_penalty_modal_component/attach_penalty_modal_component.html.erb`

## Props

### `list` (required)
The list to which penalties will be attached.
- **Type**: List (any STI subclass)
- **Used For**:
  - Generating form submission URL
  - Filtering available penalties by media type
  - Displaying media type context in UI

## Template Structure

### Container
Wrapped in `<div id="attach_penalty_modal">` for Turbo Stream replacement.

### Modal Dialog
Uses DaisyUI modal component (`dialog.modal`) with ID `attach_penalty_modal_dialog`.

### Form
- **Model**: `ListPenalty.new`
- **URL**: `admin_list_list_penalties_path(@list)`
- **Method**: POST
- **Stimulus Controller**: `modal-form` (auto-closes modal on success)
- **Data Attributes**:
  - `modal_form_modal_id_value: "attach_penalty_modal_dialog"` - Links form to modal
  - `turbo_frame: "list_penalties_list"` - Targets Turbo Stream replacement

### Penalty Selection
- **Field**: Select dropdown for `penalty_id`
- **Options**: Populated via component's `available_penalties` method
- **Filtering Logic**: Only shows compatible penalties (Global + matching media type)
- **Exclusions**: Penalties already attached to the list
- **Label Text**: Shows media type context (e.g., "Only compatible penalties shown (Global + Music)")

### Actions
- **Cancel Button**: Closes modal without submission
- **Submit Button**: "Attach Penalty" - submits form via Turbo Stream

## Public Methods

### `#available_penalties`
Returns an ActiveRecord::Relation of penalties available for attachment to the list.

**Filtering Logic**:
1. **Static Only**: Excludes dynamic penalties (can't be manually attached)
2. **Media Compatibility**: Shows `Global::Penalty` + media-specific penalties matching list type
3. **Not Already Attached**: Excludes penalties already in `list.penalties`
4. **Ordered**: Alphabetically by penalty name

**Returns**: `ActiveRecord::Relation<Penalty>`

**Implementation**:
```ruby
def available_penalties
  media_type = @list.type.split("::").first

  Penalty
    .static
    .where("type IN (?, ?)", "Global::Penalty", "#{media_type}::Penalty")
    .where.not(id: @list.penalties.pluck(:id))
    .order(:name)
end
```

**Design Note**: This method is self-contained within the component, making it independent of helper modules. This ensures the component works correctly even when `ActionController::Base.include_all_helpers = false` (Rails 8 best practice).

## Turbo Stream Integration

### Replacement Target
The outer `<div id="attach_penalty_modal">` serves as the replacement target when:
- A penalty is successfully attached (refreshes available options)
- A penalty is detached (refreshes available options)

### Stimulus Controller
The `modal-form` Stimulus controller handles:
- Auto-closing modal on successful form submission
- Managing modal state
- Coordinating with Turbo Stream responses

## Usage Examples

### In Album List Show Page
```erb
<%= render Admin::AttachPenaltyModalComponent.new(list: @list) %>
```

### In Song List Show Page
```erb
<%= render Admin::AttachPenaltyModalComponent.new(list: @list) %>
```

### In Turbo Stream Response
```ruby
turbo_stream.replace(
  "attach_penalty_modal",
  Admin::AttachPenaltyModalComponent.new(list: @list)
)
```

## UI Pattern

### Modal Trigger
The component only renders the modal dialog itself. The trigger button is typically placed elsewhere in the UI:
```erb
<button onclick="attach_penalty_modal_dialog.showModal()">
  Attach Penalty
</button>
```

### Real-Time Updates
When a penalty is attached/detached:
1. Controller creates/destroys ListPenalty record
2. Controller responds with Turbo Stream
3. Turbo Stream replaces `#attach_penalty_modal` with fresh component
4. Fresh component reflects updated available penalties list
5. Modal auto-closes via Stimulus controller

## Cross-Domain Design
The component is intentionally domain-agnostic:
- Works with any List STI type
- Media type detection via `@list.type.split("::").first`
- Penalty filtering delegated to helper method
- No hardcoded media-specific logic in component

## Dependencies
- `Admin::ListPenaltiesHelper#available_penalties` - Filters available penalties
- DaisyUI CSS framework for modal styles
- Turbo for form submission and stream replacement
- Stimulus `modal-form` controller for auto-close behavior

## Related Components
- `Admin::ListPenaltiesController` - Handles form submission and Turbo Stream responses
- ListPenalty model - Validates penalty attachment
- Penalty model - Provides `.static` scope and media type filtering

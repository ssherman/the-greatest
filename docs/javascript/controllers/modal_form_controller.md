# modal_form_controller.js

## Summary
Stimulus controller that automatically closes modals after successful form submissions. Listens for Turbo's `turbo:submit-end` event and closes the modal when the form submission succeeds (2xx status code).

## Purpose
Provides seamless UX by auto-closing modals after add/edit operations complete successfully, while keeping them open if validation errors occur.

## Values

### `modalId` (String, required)
The DOM ID of the modal element to close.

## Usage

```erb
<%= form_with model: @record,
              url: some_path,
              data: {
                controller: "modal-form",
                modal_form_modal_id_value: "my_modal_id"
              } do |f| %>
  <!-- form fields -->
<% end %>
```

## Behavior

1. **On Connect**: Attaches event listener for `turbo:submit-end` on the form element
2. **On Submit End**:
   - Checks `event.detail.success` (true for 2xx status codes)
   - If successful:
     - Closes modal using `document.getElementById(modalId).close()`
     - Resets form using `element.reset()`
   - If unsuccessful: Does nothing (modal stays open to show errors)
3. **On Disconnect**: Removes event listener for cleanup

## Event Handling

Relies on Turbo's built-in events:
- `turbo:submit-end` - Fires after form submission completes
  - `event.detail.success` - Boolean indicating HTTP success (2xx status)
  - `event.detail.fetchResponse` - Full fetch response object

## Integration

Works with:
- **Turbo Frames**: Form can be inside or outside a turbo frame
- **Turbo Streams**: Controller detects success regardless of response format
- **DaisyUI Modals**: Uses native `<dialog>` element's `.close()` method
- **form_with**: Compatible with Rails `form_with` helper

## Example Use Cases

1. **Add Record Modal**: Auto-closes after creating new record
2. **Edit Record Modal**: Auto-closes after updating record
3. **Multi-step Forms**: Can be chained with other controllers for complex flows

## Dependencies
- Stimulus framework
- Turbo (for `turbo:submit-end` event)
- Native `<dialog>` element (DaisyUI modal)

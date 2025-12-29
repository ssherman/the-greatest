# Admin::Music::Albums::Wizard::SharedModalComponent

## Summary
ViewComponent that renders a single reusable `<dialog>` element for on-demand modal loading. Modal content is loaded via Turbo Frames when action links are clicked, improving performance by avoiding per-item modal rendering.

## Initialization

```ruby
Admin::Music::Albums::Wizard::SharedModalComponent.new
```

No parameters required.

## Constants

### DIALOG_ID
`"shared_modal_dialog"` - DOM ID for the dialog element.

### FRAME_ID
`"shared_modal_content"` - ID for the Turbo Frame that receives modal content.

### ERROR_ID
`"shared_modal_error"` - ID for the error message container inside modals.

## Public Methods

### dialog_id
Returns `DIALOG_ID` constant.

### frame_id
Returns `FRAME_ID` constant.

### error_id
Returns `ERROR_ID` constant.

## Template Structure

```html
<dialog id="shared_modal_dialog" class="modal"
        data-controller="shared-modal"
        data-action="turbo:frame-load->shared-modal#open">
  <div class="modal-box max-w-2xl overflow-visible">
    <turbo-frame id="shared_modal_content">
      <!-- Loading spinner placeholder -->
    </turbo-frame>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>
```

## Stimulus Controller

Uses `shared_modal_controller.js`:

### Actions
- `turbo:frame-load->shared-modal#open` - Opens modal when content loads

### Methods
- `open()` - Calls `this.element.showModal()`
- `clear()` - Resets frame to loading spinner on close
- `close()` - Programmatically closes the dialog

## Usage Pattern

### In ReviewStepComponent
```erb
<%= render(Admin::Music::Albums::Wizard::SharedModalComponent.new) %>
```

### Action Links
```erb
<%= link_to "Edit Metadata",
    modal_admin_albums_list_item_path(list_id: list.id, id: item.id, modal_type: :edit_metadata),
    data: { turbo_frame: Admin::Music::Albums::Wizard::SharedModalComponent::FRAME_ID } %>
```

### Modal Content Partials
All modal partials wrap content in the shared frame:
```erb
<%= turbo_frame_tag Admin::Music::Albums::Wizard::SharedModalComponent::FRAME_ID do %>
  <!-- Modal content -->
<% end %>
```

### Error Display in Modals
```erb
<div id="<%= Admin::Music::Albums::Wizard::SharedModalComponent::ERROR_ID %>"
     class="text-error text-sm mt-2"></div>
```

## Benefits
- Single dialog instance instead of one per item
- Content loads on-demand, reducing initial page weight
- Turbo Frame automatically handles content replacement
- Dialog auto-opens on `turbo:frame-load` event
- Content clears on close to prevent stale data

## Related Files
- Template: `app/components/admin/music/albums/wizard/shared_modal_component.html.erb`
- Stimulus: `app/javascript/controllers/shared_modal_controller.js`
- Modal partials: `app/views/admin/music/albums/list_items_actions/modals/`
- Controller action: `Admin::Music::Albums::ListItemsActionsController#modal`

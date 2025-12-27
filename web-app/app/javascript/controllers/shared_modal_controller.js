import { Controller } from "@hotwired/stimulus"

// Controller for the shared modal dialog.
// Opens the dialog when content loads via Turbo Frame, clears content on close.
//
// Usage on dialog element:
//   data-controller="shared-modal"
//   data-action="turbo:frame-load->shared-modal#open close->shared-modal#clear"
//
// Connects to data-controller="shared-modal"
export default class extends Controller {
  static targets = ["frame"]

  connect() {
    // Listen for the dialog's own close event (not bubbled from children)
    // The autoComplete.js library dispatches 'close' events that bubble up,
    // so we need to check that the event target is the dialog itself
    this.boundHandleClose = this.handleClose.bind(this)
    this.element.addEventListener('close', this.boundHandleClose)
  }

  disconnect() {
    this.element.removeEventListener('close', this.boundHandleClose)
  }

  handleClose(event) {
    // Only clear if this is the dialog's own close event, not a bubbled event
    if (event.target === this.element) {
      this.clear()
    }
  }

  // Called when turbo:frame-load event fires (content loaded into frame)
  open() {
    this.element.showModal()
  }

  // Called when the dialog closes (cancel, ESC, backdrop click, or form submission)
  // Clears the frame content so stale content isn't shown next time
  clear() {
    const frame = this.element.querySelector("turbo-frame")
    if (frame) {
      // Reset to loading spinner
      frame.innerHTML = `
        <div class="flex justify-center py-8">
          <span class="loading loading-spinner loading-lg"></span>
        </div>
      `
    }
  }

  // Programmatically close the dialog (can be called from other controllers)
  close() {
    this.element.close()
  }
}

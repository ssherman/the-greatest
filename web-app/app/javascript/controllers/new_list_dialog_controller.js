import { Controller } from "@hotwired/stimulus"

// Resets the My Lists "New list" dialog before Turbo snapshots the page.
// Turbo caches the DOM as-is, so after a successful create (a redirect) Back
// would restore the dialog open, non-modal, with the old name still typed.
// Not data-turbo-temporary: that would drop the dialog from the snapshot and
// leave the "+ New list" button with nothing to open. See csv_export_controller.js.
export default class extends Controller {
  static targets = ["form", "errors"]

  connect() {
    this._resetForCache = () => {
      this.element.close?.()
      this.formTarget.reset()
      this.errorsTarget.textContent = ""
    }
    document.addEventListener("turbo:before-cache", this._resetForCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this._resetForCache)
  }
}

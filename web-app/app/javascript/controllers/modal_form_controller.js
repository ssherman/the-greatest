import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="modal-form"
export default class extends Controller {
  static values = {
    modalId: String
  }

  connect() {
    // Listen for successful turbo:submit-end events
    this.element.addEventListener("turbo:submit-end", this.handleSubmitEnd.bind(this))
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-end", this.handleSubmitEnd.bind(this))
  }

  handleSubmitEnd(event) {
    // Check if the submission was successful (2xx status code)
    if (event.detail.success) {
      const modal = document.getElementById(this.modalIdValue)
      if (modal) {
        modal.close()
        // Reset the form after closing
        this.element.reset()
      }
    }
  }
}

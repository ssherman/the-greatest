import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="admin--search"
export default class extends Controller {
  static targets = ["input", "form"]
  static values = {
    url: String,
    debounce: { type: Number, default: 300 }
  }

  connect() {
    this.timeout = null
  }

  disconnect() {
    this.clearTimeout()
  }

  search(event) {
    this.clearTimeout()

    const query = this.inputTarget.value.trim()

    // Debounce the search
    this.timeout = setTimeout(() => {
      this.performSearch(query)
    }, this.debounceValue)
  }

  performSearch(query) {
    // Submit the form to trigger Turbo Frame update
    this.formTarget.requestSubmit()
  }

  clearTimeout() {
    if (this.timeout) {
      clearTimeout(this.timeout)
      this.timeout = null
    }
  }
}

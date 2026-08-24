import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="metadata-editor"
// Validates JSON in a textarea and enables/disables submit button
export default class extends Controller {
  static targets = ["textarea", "error", "submitButton"]

  connect() {
    this.validate()
  }

  validate() {
    const value = this.textareaTarget.value

    if (!value || value.trim() === "") {
      this.showError("JSON cannot be empty")
      this.disableSubmit()
      return
    }

    try {
      JSON.parse(value)
      this.clearError()
      this.enableSubmit()
    } catch (e) {
      this.showError(`Invalid JSON: ${e.message}`)
      this.disableSubmit()
    }
  }

  showError(message) {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = message
    }
  }

  clearError() {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = ""
    }
  }

  enableSubmit() {
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = false
    }
  }

  disableSubmit() {
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = true
    }
  }
}

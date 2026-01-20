import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="year-range-modal"
// Handles custom year range filtering with URL building for different filter types:
// - Both years: range or single year URL
// - Only from: since URL
// - Only to: through URL
export default class extends Controller {
  static targets = ["fromYear", "toYear", "applyButton", "error"]
  static values = { basePath: String }

  connect() {
    this.validate()
  }

  validate() {
    const from = this.fromYearTarget.value.trim()
    const to = this.toYearTarget.value.trim()

    // Clear error state
    this.errorTarget.textContent = ""
    this.errorTarget.classList.add("hidden")

    // Check if at least one field is filled
    if (!from && !to) {
      this.applyButtonTarget.disabled = true
      return
    }

    // Validate year format (4 digits)
    const yearRegex = /^\d{4}$/
    if (from && !yearRegex.test(from)) {
      this.showError("From year must be a 4-digit year")
      this.applyButtonTarget.disabled = true
      return
    }
    if (to && !yearRegex.test(to)) {
      this.showError("To year must be a 4-digit year")
      this.applyButtonTarget.disabled = true
      return
    }

    // Validate range (from <= to) if both are filled
    if (from && to && parseInt(from) > parseInt(to)) {
      this.showError("From year cannot be greater than To year")
      this.applyButtonTarget.disabled = true
      return
    }

    // Valid
    this.applyButtonTarget.disabled = false
  }

  apply() {
    const url = this.buildUrl()
    if (url) {
      window.location.href = url
    }
  }

  buildUrl() {
    const from = this.fromYearTarget.value.trim()
    const to = this.toYearTarget.value.trim()
    const base = this.basePathValue

    if (!from && !to) return null
    if (from && !to) return `${base}/since/${from}`
    if (!from && to) return `${base}/through/${to}`
    if (from === to) return `${base}/${from}`
    return `${base}/${from}-${to}`
  }

  showError(message) {
    this.errorTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
  }
}

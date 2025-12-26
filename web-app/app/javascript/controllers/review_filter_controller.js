import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="review-filter"
// CSS-based filtering of review table rows by status for performance.
// Instead of iterating 1000+ rows in JS, we set a data attribute on the
// container and let CSS hide/show rows. This is O(1) instead of O(n).
export default class extends Controller {
  static targets = ["container", "filter", "count"]
  static values = {
    totalCount: Number,
    validCount: Number,
    invalidCount: Number,
    missingCount: Number
  }

  connect() {
    this.filter()
  }

  filter() {
    // Guard against missing container (when items list is empty)
    if (!this.hasContainerTarget) return

    const value = this.filterTarget.value

    // Single DOM write - CSS handles the rest
    this.containerTarget.dataset.filter = value

    // Use pre-computed counts instead of iterating DOM
    const count = this.getCountForFilter(value)
    this.countTarget.textContent = `Showing ${count} items`
  }

  getCountForFilter(filter) {
    switch (filter) {
      case "valid":
        return this.validCountValue
      case "invalid":
        return this.invalidCountValue
      case "missing":
        return this.missingCountValue
      default:
        return this.totalCountValue
    }
  }
}

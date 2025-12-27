import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="review-filter"
// CSS-based filtering of review table rows by status for performance.
// Instead of iterating 1000+ rows in JS, we set a data attribute on the
// container and let CSS hide/show rows. This is O(1) instead of O(n).
//
// Counts are tracked via Stimulus values and updated via MutationObserver
// when Turbo Stream responses modify row statuses (verify, link, etc.).
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
    this.observeRowChanges()
  }

  disconnect() {
    if (this.observer) {
      this.observer.disconnect()
    }
  }

  filter() {
    // Guard against missing container (when items list is empty)
    if (!this.hasContainerTarget) return

    const value = this.filterTarget.value

    // Single DOM write - CSS handles the rest
    this.containerTarget.dataset.filter = value

    // Use tracked counts instead of iterating DOM
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

  // Watch for Turbo Stream updates that change row statuses
  observeRowChanges() {
    if (!this.hasContainerTarget) return

    this.observer = new MutationObserver((mutations) => {
      let needsRecount = false

      for (const mutation of mutations) {
        // Check for added/removed rows or attribute changes
        if (mutation.type === 'childList' ||
            (mutation.type === 'attributes' && mutation.attributeName === 'data-status')) {
          needsRecount = true
          break
        }
      }

      if (needsRecount) {
        this.recountFromDOM()
      }
    })

    this.observer.observe(this.containerTarget, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['data-status']
    })
  }

  // Recount statuses from DOM after Turbo Stream updates
  recountFromDOM() {
    if (!this.hasContainerTarget) return

    const rows = this.containerTarget.querySelectorAll('tr[data-status]')
    let valid = 0, invalid = 0, missing = 0

    rows.forEach(row => {
      switch (row.dataset.status) {
        case 'valid':
          valid++
          break
        case 'invalid':
          invalid++
          break
        case 'missing':
          missing++
          break
      }
    })

    // Update Stimulus values
    this.totalCountValue = rows.length
    this.validCountValue = valid
    this.invalidCountValue = invalid
    this.missingCountValue = missing

    // Refresh the displayed count for current filter
    const count = this.getCountForFilter(this.filterTarget.value)
    this.countTarget.textContent = `Showing ${count} items`
  }
}

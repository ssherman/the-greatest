import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="review-filter"
// Client-side filtering of review table rows by status
export default class extends Controller {
  static targets = ["row", "filter", "count"]

  connect() {
    this.filter()
  }

  filter() {
    const value = this.filterTarget.value
    let visibleCount = 0

    this.rowTargets.forEach(row => {
      const status = row.dataset.status
      const visible = value === "all" || status === value
      row.classList.toggle("hidden", !visible)
      if (visible) visibleCount++
    })

    this.countTarget.textContent = `Showing ${visibleCount} items`
  }
}

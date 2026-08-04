import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="books--filter-search"
export default class extends Controller {
  static targets = ["query", "option"]

  filter() {
    const query = this.queryTarget.value.trim().toLowerCase()

    this.optionTargets.forEach((option) => {
      const label = option.dataset.filterLabel || ""
      option.classList.toggle("hidden", query !== "" && !label.includes(query))
    })
  }
}

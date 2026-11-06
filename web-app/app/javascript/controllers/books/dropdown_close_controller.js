import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="books--dropdown-close"
//
// A <details> dropdown stays open when you click one of its links, because the
// click navigates away before anything closes it. Turbo then snapshots the page
// with the menu open, and Back restores it open. Closing it just before the
// snapshot is taken fixes that.
export default class extends Controller {
  connect() {
    this.onBeforeCache = () => this.element.removeAttribute("open")
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.onBeforeCache)
  }
}

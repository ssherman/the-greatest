import { Controller } from "@hotwired/stimulus"

// A server-rendered toast (Toast::MessageComponent). Removes itself after ttl
// with the same fade toast_controller.js uses for client-built toasts.
export default class extends Controller {
  static values = { ttl: { type: Number, default: 4000 } }

  connect() {
    this.fadeTimer = setTimeout(() => {
      this.element.classList.add("opacity-0", "transition-opacity")
      this.removeTimer = setTimeout(() => this.element.remove(), 300)
    }, this.ttlValue)
  }

  disconnect() {
    clearTimeout(this.fadeTimer)
    clearTimeout(this.removeTimer)
  }
}

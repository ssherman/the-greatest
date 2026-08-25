import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="auto-dismiss"
//
// Removes its element after delayValue milliseconds. Used by the admin
// list-items flash partials, which pass data-auto-dismiss-delay-value="3000".
// Those partials referenced this controller before it existed, so the
// behaviour they were written for has never actually run.
export default class extends Controller {
  static values = { delay: { type: Number, default: 3000 } }

  connect() {
    // Turbo caches the mutated DOM and re-runs connect() on restore, so an
    // already-scheduled timer must be cleared before scheduling another --
    // otherwise a Back navigation stacks timers on the same element.
    this.clearTimer()
    this.timer = setTimeout(() => this.element.remove(), this.delayValue)
  }

  disconnect() {
    this.clearTimer()
  }

  clearTimer() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  }
}

import { Controller } from "@hotwired/stimulus"

const POLL_MS = 5000
const IN_PROGRESS = ["queued", "running"]

// Connects to data-controller="ranking-configuration-status".
//
// While a refresh is queued or running, asks the owner-only state endpoint
// every few seconds and reloads the page once the run has finished, so the
// status panel, badge and Refresh button re-render from the server. The page
// is complete without this -- a failed poll just tries again.
export default class extends Controller {
  static values = { url: String, active: Boolean }

  connect() {
    if (!this.activeValue || !this.hasUrlValue) return
    this.timer = setInterval(() => this.poll(), POLL_MS)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async poll() {
    try {
      const response = await fetch(this.urlValue, {
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
      if (!response.ok) return

      const data = await response.json()
      if (IN_PROGRESS.includes(data.refresh_status)) return

      clearInterval(this.timer)
      window.Turbo.visit(window.location.href, { action: "replace" })
    } catch {
      // Keep polling on a transient failure.
    }
  }
}

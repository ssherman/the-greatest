import { Controller } from "@hotwired/stimulus"

const POLL_MS = 5000
const IN_PROGRESS = ["queued", "running"]

// Connects to data-controller="ranking-configuration-status".
//
// While a refresh is queued or running, asks the owner-only state endpoint
// every few seconds and reloads the page once the run has finished, so the
// status panel, badge and Refresh button re-render from the server. The page
// is complete without this -- a failed poll just tries again, except on a
// 401/403/404 (session expired, or the configuration was deleted): that
// response will never turn into a completed run, so the poller stops.
export default class extends Controller {
  static values = { url: String, active: Boolean }

  connect() {
    this.stopped = false
    this.abortController = null
    if (!this.activeValue || !this.hasUrlValue) return
    this.timer = setInterval(() => this.poll(), POLL_MS)
  }

  disconnect() {
    this.stopped = true
    clearInterval(this.timer)
    this.abortController?.abort()
  }

  async poll() {
    if (this.abortController) return // a poll is already in flight

    this.abortController = new AbortController()
    try {
      const response = await fetch(this.urlValue, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
        signal: this.abortController.signal
      })
      if (!response.ok) {
        if ([401, 403, 404].includes(response.status)) clearInterval(this.timer)
        return
      }

      const data = await response.json()
      if (this.stopped) return
      // Keep polling while the server still calls the run live. A run that
      // has gone stale is claimable again: reload so the page shows the
      // stalled copy and enables the Refresh button.
      if (IN_PROGRESS.includes(data.refresh_status) && !data.claimable) return

      clearInterval(this.timer)
      window.Turbo.visit(window.location.href, { action: "replace" })
    } catch {
      // Aborted by disconnect(), or a transient failure -- either way,
      // there's nothing to do beyond what disconnect()/the next tick handles.
    } finally {
      this.abortController = null
    }
  }
}

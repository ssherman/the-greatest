import { Controller } from "@hotwired/stimulus"

// Keeps the cacheable public goal page viewer-neutral. Only a browser carrying
// the signed-in marker asks the no-store endpoint whether Manage can be shown.
export default class extends Controller {
  static targets = ["manage"]
  static values = {
    goalId: Number,
    stateUrl: String
  }

  connect() {
    this.onAuthSignout = this.reset.bind(this)
    this.onBeforeCache = this.reset.bind(this)
    window.addEventListener("auth:signout", this.onAuthSignout)
    document.addEventListener("turbo:before-cache", this.onBeforeCache)

    this.reset()
    if (!this.hasGoalIdValue || this.goalIdValue <= 0 || !this.hasStateUrlValue) return
    if (!this.hasSignedInCookie()) return

    this.loadState()
  }

  disconnect() {
    window.removeEventListener("auth:signout", this.onAuthSignout)
    document.removeEventListener("turbo:before-cache", this.onBeforeCache)
    this.reset()
  }

  async loadState() {
    const request = new AbortController()
    this.stateRequest = request

    try {
      const response = await fetch(this.stateUrlValue, {
        credentials: "same-origin",
        headers: { "Accept": "application/json" },
        signal: request.signal
      })
      if (!response.ok) return

      const data = await response.json()
      if (request.signal.aborted || !data.can_manage || !data.manage_url) return

      this.manageTarget.href = data.manage_url
      this.manageTarget.classList.remove("hidden")
    } catch {
      // The public page is complete without management state. A failed
      // enhancement remains hidden rather than affecting the cached content.
    } finally {
      if (this.stateRequest === request) this.stateRequest = null
    }
  }

  reset() {
    this.stateRequest?.abort()
    this.stateRequest = null
    this.manageTarget.classList.add("hidden")
    this.manageTarget.removeAttribute("href")
  }

  hasSignedInCookie() {
    return document.cookie
      .split(";")
      .some((cookie) => cookie.trim().startsWith("tg_uid="))
  }
}

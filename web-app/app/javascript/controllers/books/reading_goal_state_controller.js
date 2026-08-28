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
    if (!this.hasGoalIdValue || this.goalIdValue <= 0 || !this.hasStateUrlValue) return
    if (!this.hasSignedInCookie()) return

    this.loadState()
  }

  async loadState() {
    try {
      const response = await fetch(this.stateUrlValue, {
        credentials: "same-origin",
        headers: { "Accept": "application/json" }
      })
      if (!response.ok) return

      const data = await response.json()
      if (!data.can_manage || !data.manage_url) return

      this.manageTarget.href = data.manage_url
      this.manageTarget.classList.remove("hidden")
    } catch {
      // The public page is complete without management state. A failed
      // enhancement remains hidden rather than affecting the cached content.
    }
  }

  hasSignedInCookie() {
    return document.cookie
      .split(";")
      .some((cookie) => cookie.trim().startsWith("tg_uid="))
  }
}

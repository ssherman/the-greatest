import { Controller } from "@hotwired/stimulus"

// The Download CSV button on edge-cached pages (spec §11).
//
// The page cannot know who is looking at it, so the decision is made on click:
//   - no tg_uid cookie   -> open the sign-in modal (same check as
//                           user_list_widget_controller.js)
//   - state check 401    -> stale sign-in marker: open the sign-in modal
//   - state says member  -> follow the link; the server sends the file
//   - anything else      -> show the top-500 dialog. Safe in the direction
//                           that matters: a member who hits this fallback sees
//                           one unnecessary dialog, and "Download top 500"
//                           points at the same URL, so the server still gives
//                           them the full file.
//
// Membership comes from the per-user state user_list_state_controller.js
// caches. The click re-checks it (conditionally, so usually a 304) rather than
// trusting the cache, because a member who has just paid must not be shown the
// non-member dialog. That request is the click's, not the page load's.
//
// The dialog is closed on turbo:before-cache (see books/nav_drawer_controller.js):
// Turbo snapshots the DOM as-is, so an open <dialog> would come back on Back as
// an open, non-modal dialog with no backdrop.
export default class extends Controller {
  static values = {
    modal: String
  }

  connect() {
    this._closeForCache = () => document.getElementById(this.modalValue)?.close?.()
    document.addEventListener("turbo:before-cache", this._closeForCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this._closeForCache)
  }

  async download(event) {
    event.preventDefault()
    const href = event.currentTarget.href

    if (!this.cookieUid()) {
      document.getElementById("login_modal")?.showModal?.()
      return
    }

    const stateCtrl = this.application.getControllerForElementAndIdentifier(document.body, "user-list-state")
    const status = await stateCtrl?.refresh?.({ conditional: true })

    // A 401 means the tg_uid cookie outlived the Rails session.
    if (status === "unauthenticated") {
      document.getElementById("login_modal")?.showModal?.()
      return
    }

    // After a failed check this is the entry as it stood, or nothing at all.
    if (stateCtrl?.state?.()?.membership?.member) {
      window.location.assign(href)
      return
    }

    document.getElementById(this.modalValue)?.showModal?.()
  }

  cookieUid() {
    const m = document.cookie.match(/(?:^|;\s*)tg_uid=([^;]+)/)
    return m ? decodeURIComponent(m[1]) : null
  }
}

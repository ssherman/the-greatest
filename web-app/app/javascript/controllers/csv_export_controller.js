import { Controller } from "@hotwired/stimulus"

// The Download CSV button on edge-cached pages (spec §11).
//
// The page cannot know who is looking at it, so the decision is made on click:
//   - no tg_uid cookie      -> open the sign-in modal (same check as
//                              user_list_widget_controller.js)
//   - /membership_state 401 -> stale sign-in marker: open the sign-in modal
//   - /membership_state ok  -> member: follow the link; the server sends the
//                              file
//   - anything else         -> show the top-500 dialog. Safe in the direction
//                              that matters: a member who hits this fallback
//                              sees one unnecessary dialog, and "Download top
//                              500" points at the same URL, so the server
//                              still gives them the full file.
//
// The dialog is closed on turbo:before-cache (see books/nav_drawer_controller.js):
// Turbo snapshots the DOM as-is, so an open <dialog> would come back on Back as
// an open, non-modal dialog with no backdrop.
export default class extends Controller {
  static values = {
    modal: String,
    stateUrl: { type: String, default: "/membership_state" }
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

    const isMember = await this.member()

    if (this.unauthenticated) {
      document.getElementById("login_modal")?.showModal?.()
      return
    }

    if (isMember) {
      window.location.assign(href)
      return
    }

    document.getElementById(this.modalValue)?.showModal?.()
  }

  // Sets this.unauthenticated as a side effect: a 401 means the tg_uid cookie
  // outlived the Rails session, which download() treats as "not signed in".
  async member() {
    this.unauthenticated = false
    try {
      const response = await fetch(this.stateUrlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      this.unauthenticated = response.status === 401
      if (!response.ok) return false
      const state = await response.json()
      return !!state.member
    } catch (_e) {
      return false
    }
  }

  cookieUid() {
    const m = document.cookie.match(/(?:^|;\s*)tg_uid=([^;]+)/)
    return m ? decodeURIComponent(m[1]) : null
  }
}

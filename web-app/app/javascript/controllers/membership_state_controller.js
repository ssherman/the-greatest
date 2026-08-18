import { Controller } from "@hotwired/stimulus"

// Reveals the members-only nav link on edge-cached pages.
//
// The navbar ships in CDN-cached HTML that is identical for every visitor, so
// the Members link is rendered hidden and revealed here once /membership_state
// confirms the signed-in user is a member. Same approach as the My Lists link
// and the Login/Logout toggle.
export default class extends Controller {
  static values = {
    url: { type: String, default: "/membership_state" }
  }

  connect() {
    // Same event this app's login modal dispatches on sign-out — see
    // user_list_state_controller.js. Without this, a member who signs out
    // in-page (no navigation) would keep seeing the revealed link until the
    // next Turbo visit re-runs connect(), which on a shared browser discloses
    // the previous user's membership the same way the tg_uid cookie gate
    // below is meant to prevent.
    //
    // auth:success is deliberately NOT handled here: every place in this app
    // that renders the sign-in modal passes reload_after_auth: true, so a
    // successful sign-in always triggers a full page reload (see
    // authentication_controller.js#handleAuthSuccess), which re-runs connect()
    // on a fresh page anyway. A listener here would just duplicate that fetch.
    this._onAuthSignout = this._onAuthSignout.bind(this)
    window.addEventListener("auth:signout", this._onAuthSignout)

    // Gated on the tg_uid cookie set by AuthController at sign-in. Without a
    // signed-in marker the endpoint would just 401, so skip the request.
    if (!this.cookieUid()) {
      this.reveal(false)
      return
    }

    this.refresh()
  }

  disconnect() {
    window.removeEventListener("auth:signout", this._onAuthSignout)
  }

  async refresh() {
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      if (!response.ok) {
        this.reveal(false)
        return
      }
      const state = await response.json()
      this.reveal(!!state.member)
    } catch (_e) {
      // A failed state fetch must never break the page. Staying hidden is the
      // safe default: the /members page re-checks membership server-side, so a
      // hidden link costs a member one click, while a wrongly-revealed one
      // would send a non-member to a redirect.
      this.reveal(false)
    }
  }

  // querySelectorAll covers both the mobile and desktop copies of the menu.
  reveal(visible) {
    document.querySelectorAll("#navbar_members").forEach((el) => {
      el.classList.toggle("hidden", !visible)
    })
  }

  cookieUid() {
    const m = document.cookie.match(/(?:^|;\s*)tg_uid=([^;]+)/)
    return m ? decodeURIComponent(m[1]) : null
  }

  _onAuthSignout() {
    this.reveal(false)
  }
}

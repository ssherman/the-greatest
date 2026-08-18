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
    // Gated on the tg_uid cookie set by AuthController at sign-in. Without a
    // signed-in marker the endpoint would just 401, so skip the request.
    if (!this.cookieUid()) {
      this.reveal(false)
      return
    }

    this.refresh()
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
}

import { Controller } from "@hotwired/stimulus"

// Reveals the members-only nav link on edge-cached pages.
//
// The navbar ships in CDN-cached HTML that is identical for every visitor, so
// the Members link is rendered hidden and revealed here once the signed-in
// user's state says they are a member. Same approach as the My Lists link and
// the Login/Logout toggle.
//
// It makes no request of its own: membership arrives with the rest of the
// per-user state that user_list_state_controller.js caches and re-checks, so
// this only listens. /membership_state still exists for pages cached before
// this change, but nothing here calls it.
export default class extends Controller {
  connect() {
    this._onState = this._onState.bind(this)
    this._onCleared = this._onCleared.bind(this)
    window.addEventListener("user-list-state:loaded", this._onState)
    window.addEventListener("user-list-state:updated", this._onState)
    window.addEventListener("user-list-state:cleared", this._onCleared)
    // Same event this app's login modal dispatches on sign-out. Without it, a
    // member who signs out in-page (no navigation) would keep seeing the
    // revealed link, which on a shared browser discloses the previous user's
    // membership the same way the tg_uid gate below is meant to prevent.
    //
    // auth:success is deliberately NOT handled here: every place in this app
    // that renders the sign-in modal passes reload_after_auth: true, so a
    // successful sign-in always triggers a full page reload (see
    // authentication_controller.js#handleAuthSuccess), which re-runs connect()
    // on a fresh page anyway.
    window.addEventListener("auth:signout", this._onCleared)

    // The state controller may have connected (and announced its entry) before
    // this one, so read what it holds now; a later announcement arrives through
    // the listeners above. Runs again on a Turbo restore, whose snapshot may
    // hold a link revealed for whoever was signed in when it was taken.
    if (!this.cookieUid()) {
      this.reveal(false)
      return
    }
    const stateCtrl = this.application.getControllerForElementAndIdentifier(document.body, "user-list-state")
    this._render(stateCtrl?.state?.())
  }

  disconnect() {
    window.removeEventListener("user-list-state:loaded", this._onState)
    window.removeEventListener("user-list-state:updated", this._onState)
    window.removeEventListener("user-list-state:cleared", this._onCleared)
    window.removeEventListener("auth:signout", this._onCleared)
  }

  _onState(event) {
    this._render(event.detail?.state)
  }

  _onCleared() {
    this.reveal(false)
  }

  // Staying hidden is the safe default, for no tg_uid and for no state alike:
  // the /members page re-checks membership server-side, so a hidden link costs
  // a member one click, while a wrongly-revealed one would send a non-member to
  // a redirect.
  _render(state) {
    this.reveal(!!this.cookieUid() && !!state?.membership?.member)
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

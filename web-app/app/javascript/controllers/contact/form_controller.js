import { Controller } from "@hotwired/stimulus"

// The footer is rendered on every public page and every public page is
// edge-cached, so the form's HTML is identical for everyone: no email baked in,
// and an authenticity token belonging to whoever populated the cache.
//
// This fetches the visitor's own token and email from /contact_state when the
// modal OPENS -- not on page load, so a crawler that never opens it never
// reaches the endpoint; and not on first focus (which is what corrections does)
// because a signed-in visitor should see their address already filled in rather
// than watch it appear after they click elsewhere.
//
// If the fetch fails there is deliberately no error and no blocked submit: the
// server's protect_from_forgery :null_session accepts the write as anonymous.
// Losing attribution beats a 422 the submitter cannot act on.
export default class extends Controller {
  static targets = ["form", "email", "dialog"]
  static values = { stateUrl: String }

  connect() {
    this.stateFetched = false
    this._inflight = null
    // Captured once, from the cached page's own markup, before anything can
    // have replaced it. This is what open() restores after a successful send
    // swaps #contact_modal_body for the thanks panel -- otherwise reopening
    // the dialog shows "Thanks" again with no way to send a second message.
    this._pristineFormHTML = this._bodyElement()?.innerHTML ?? null
  }

  open() {
    const body = this._bodyElement()
    if (body && this._pristineFormHTML && !body.querySelector("form")) {
      body.innerHTML = this._pristineFormHTML
    }
    this.dialogTarget.showModal()
    this.ensureState()
  }

  close() {
    this.dialogTarget.close()
  }

  ensureState() {
    if (this.stateFetched) return this._inflight
    if (this._inflight) return this._inflight

    this._inflight = this._fetchState().finally(() => {
      this._inflight = null
    })
    return this._inflight
  }

  async _fetchState() {
    let response
    try {
      response = await fetch(this.stateUrlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
    } catch (err) {
      console.warn("contact--form: state fetch failed", err)
      return
    }

    if (!response.ok) return

    const data = await response.json()
    this.stateFetched = true

    if (data.csrf_token) this._applyToken(data.csrf_token)
    if (data.email) this._applyEmail(data.email)
  }

  _applyToken(token) {
    if (this.hasFormTarget) {
      const field = this.formTarget.querySelector('input[name="authenticity_token"]')
      if (field) field.value = token
    }

    // Also patch the page meta tag: the cached page's token is stale for every
    // other Turbo request on this page too. Same as corrections/form_controller.
    const meta = document.querySelector('meta[name="csrf-token"]')
    if (meta) meta.setAttribute("content", token)
  }

  // Read-only rather than disabled: a disabled input is not submitted at all,
  // and while the server ignores this value for a signed-in visitor, an empty
  // required field would block the browser's own validation before it got there.
  _applyEmail(email) {
    if (!this.hasEmailTarget) return
    this.emailTarget.value = email
    this.emailTarget.readOnly = true
  }

  // ensureState() is a no-op once stateFetched is true, and open() calls it on
  // every reopen regardless. A successful submission destroys the hydrated
  // form (the turbo-stream response swaps #contact_modal_body for the thanks
  // panel), and open() later puts back the PRISTINE form captured in
  // connect() -- stale token, no email, same as first page load. Reset the
  // flag here so that restored form actually gets re-hydrated the next time
  // the dialog opens, instead of ensureState() silently skipping it as
  // already-fetched.
  //
  // A failed submission re-renders the form from the server directly, from an
  // uncached response, with a fresh token already baked in -- nothing needs
  // fetching for that path. This reset only does anything for the
  // reopen-after-success case above.
  submitting() {
    this.stateFetched = false
  }

  _bodyElement() {
    return this.hasDialogTarget ? this.dialogTarget.querySelector("#contact_modal_body") : null
  }
}

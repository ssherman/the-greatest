import { Controller } from "@hotwired/stimulus"

// Edge-cached public form pages ship a <meta name="csrf-token"> and a hidden
// authenticity_token that belong to whoever populated the cache, or to nobody.
// This fetches a real one for this visitor's session and writes it into the
// form.
//
// Fetched on FIRST INTERACTION, not on connect: these pages are public and have
// been used to flood the origin, and /form_token is the only uncached endpoint
// they still touch. A crawler or a flood that never focuses an input never
// reaches it.
//
// If the fetch fails there is deliberately no error shown and no submit blocked:
// the server's protect_from_forgery :null_session accepts the write as anonymous.
// Losing attribution is a better outcome than a 422 the submitter cannot act on.
export default class extends Controller {
  static targets = ["form", "list"]
  static values = { tokenUrl: String }

  connect() {
    this.tokenFetched = false
    this._inflight = null
  }

  // Wired from the form element's focusin, so any input reaching focus arms it.
  ensureToken() {
    if (this.tokenFetched) return this._inflight
    if (this._inflight) return this._inflight

    this._inflight = this._fetchToken().finally(() => {
      this._inflight = null
    })
    return this._inflight
  }

  async _fetchToken() {
    let response
    try {
      response = await fetch(this.tokenUrlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
    } catch (err) {
      console.warn("shared--form-token: token fetch failed", err)
      return
    }

    if (!response.ok) return

    const data = await response.json()
    if (!data.csrf_token) return

    this.tokenFetched = true
    this._applyToken(data.csrf_token)
  }

  _applyToken(token) {
    const field = this.formTarget.querySelector('input[name="authenticity_token"]')
    if (field) field.value = token

    // Also patch the page meta tag: the cached page's token is stale for any
    // other Turbo request on this page too. Same as reviews/widget_controller.
    const meta = document.querySelector('meta[name="csrf-token"]')
    if (meta) meta.setAttribute("content", token)
  }

  addListItem(event) {
    const field = event.currentTarget.dataset.field
    const list = this.listTargets.find((el) => el.dataset.field === field)
    if (!list) return

    const row = document.createElement("div")
    row.className = "join w-full"

    // The input name comes from the list element, never from a literal here.
    // Two callers post different shapes: the public correction form posts
    // correction[fields][<field>][] and the admin review form posts
    // accepted[<field>][]. Reading it from the markup that already declares it
    // is what lets one controller serve both without the two drifting.
    const inputName = list.dataset.inputName
    if (!inputName) return

    const input = document.createElement("input")
    input.type = "text"
    input.name = inputName
    input.className = "input join-item w-full"

    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn join-item"
    button.dataset.action = "shared--form-token#removeListItem"
    button.textContent = "Remove"

    // createElement + textContent throughout rather than innerHTML: `field` comes
    // from a data attribute, and building markup by string concatenation is how a
    // template ends up interpolating something it should not.
    row.append(input, button)
    list.append(row)
    input.focus()
  }

  removeListItem(event) {
    event.currentTarget.closest(".join")?.remove()
  }
}

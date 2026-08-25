import { Controller } from "@hotwired/stimulus"

// The correction form's client-side behaviour. Only the list add/remove
// affordance lives here for now -- the form works without JS at all (it is a
// plain POST), and there is deliberately no fetch here yet: the cached page's
// authenticity_token belongs to whoever populated the cache, and fetching a
// live one for this visitor is a separate piece of work (the correction_token
// endpoint it will call is already live).
//
// tokenUrl is declared because the form page already stamps it into the DOM
// (data-corrections--form-token-url-value), so a browser never logs an
// "unknown value" warning for markup this controller is meant to own.
export default class extends Controller {
  static targets = ["form", "list"]
  static values = { tokenUrl: String }

  addListItem(event) {
    const field = event.currentTarget.dataset.field
    const list = this.listTargets.find((el) => el.dataset.field === field)
    if (!list) return

    const row = document.createElement("div")
    row.className = "join w-full"

    const input = document.createElement("input")
    input.type = "text"
    input.name = `correction[fields][${field}][]`
    input.className = "input join-item w-full"

    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn join-item"
    button.dataset.action = "corrections--form#removeListItem"
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

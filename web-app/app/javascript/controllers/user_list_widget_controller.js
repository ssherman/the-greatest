import { Controller } from "@hotwired/stimulus"

// One per item card / show page. Reads the current user-list-state from the
// singleton controller (via window getter) to render the icon strip and label.
export default class extends Controller {
  static values = {
    listableType: String,
    listableId: Number
  }
  static targets = ["iconStrip", "button", "label"]

  connect() {
    this._render = this._render.bind(this)
    window.addEventListener("user-list-state:loaded", this._render)
    window.addEventListener("user-list-state:updated", this._render)
    window.addEventListener("user-list-state:cleared", this._render)
    this._render()
  }

  disconnect() {
    window.removeEventListener("user-list-state:loaded", this._render)
    window.removeEventListener("user-list-state:updated", this._render)
    window.removeEventListener("user-list-state:cleared", this._render)
  }

  // If anonymous, opens the login modal. Otherwise dispatches an event to the
  // singleton modal with this card's listable identifiers.
  open(event) {
    event?.preventDefault()
    const state = this._state()
    if (!state) {
      const loginModal = document.getElementById("login_modal")
      loginModal?.showModal?.()
      return
    }
    window.dispatchEvent(new CustomEvent("user-list-modal:open", {
      detail: {
        listableType: this.listableTypeValue,
        listableId: this.listableIdValue,
        listableTitle: this.buttonTarget.dataset.listableTitle || ""
      }
    }))
  }

  _render() {
    const state = this._state()
    const lists = this._membershipLists(state)

    this._updateIconStrip(lists)
    this._updateLabel(lists)
  }

  _state() {
    const ctrl = this._stateController()
    return ctrl?.state?.() || null
  }

  _stateController() {
    if (!this._cachedStateCtrl) {
      const el = document.body
      const app = window.Stimulus
      this._cachedStateCtrl = app?.getControllerForElementAndIdentifier?.(el, "user-list-state")
    }
    return this._cachedStateCtrl
  }

  _membershipLists(state) {
    if (!state) return []
    const memberships = state.memberships?.[this.listableTypeValue] || {}
    const entries = memberships[String(this.listableIdValue)] || []
    return entries
      .map((entry) => state.lists.find((l) => l.id === entry.list_id))
      .filter(Boolean)
  }

  _updateIconStrip(lists) {
    if (!this.hasIconStripTarget) return
    this.iconStripTarget.innerHTML = ""

    const defaultIcons = lists.filter((l) => l.icon)
    const customCount = lists.length - defaultIcons.length

    defaultIcons.forEach((list) => {
      const node = this._iconNode(list.icon)
      if (node) {
        node.setAttribute("title", list.name)
        this.iconStripTarget.appendChild(node)
      }
    })

    if (customCount > 0) {
      const pill = document.createElement("span")
      pill.className = "badge badge-ghost badge-sm"
      pill.textContent = `+${customCount}`
      this.iconStripTarget.appendChild(pill)
    }

    this.iconStripTarget.classList.toggle("hidden", lists.length === 0)
  }

  _updateLabel(lists) {
    if (!this.hasLabelTarget) return
    if (lists.length === 0) {
      this.labelTarget.textContent = "Add to list"
      this.buttonTarget.classList.remove("btn-primary")
      this.buttonTarget.classList.add("btn-ghost")
    } else {
      this.labelTarget.textContent = lists.length === 1 ? "On 1 list" : `On ${lists.length} lists`
      this.buttonTarget.classList.add("btn-primary")
      this.buttonTarget.classList.remove("btn-ghost")
    }
  }

  _iconNode(name) {
    const tpl = document.getElementById("user-list-icons")
    if (!tpl) return null
    const slot = tpl.content.querySelector(`[data-icon="${name}"]`)
    if (!slot) return null
    return slot.cloneNode(true)
  }
}

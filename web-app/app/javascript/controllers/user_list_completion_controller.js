import { Controller } from "@hotwired/stimulus"

// A single dialog is shared by every completion-date trigger on a list page.
// The trigger provides only the item id plus its display values; the form action
// and editable date are populated immediately before native dialog opens.
export default class extends Controller {
  static targets = ["dialog", "form", "title", "date", "variant"]

  open(event) {
    this.opener = event.currentTarget
    this.itemId = this.opener.dataset.itemId
    this.variant = this.opener.dataset.variant
    const { itemId, itemTitle, completedOn } = this.opener.dataset

    this.formTarget.action = `/user_list_items/${itemId}/completion`
    this.titleTarget.textContent = `Edit completion date for ${itemTitle}`
    this.dateTarget.value = completedOn || ""
    this.variantTarget.value = this.opener.dataset.variant || "table"
    this.dialogTarget.showModal()
    this.dateTarget.focus()
  }

  clear() {
    this.dateTarget.value = ""
    this.formTarget.requestSubmit()
  }

  // The Turbo Stream response has already updated the page; just close.
  submitted(event) {
    if (!event.detail.success) return
    // Every opener of this item must offer the saved value, not the one it had on load.
    this.element.querySelectorAll(`[data-action~="user-list-completion#open"][data-item-id="${this.itemId}"]`)
      .forEach((opener) => { opener.dataset.completedOn = this.dateTarget.value })
    this.dialogTarget.close()
    this.restoreFocusAfterRender()
  }

  // Turbo renders the stream after a repaint, which is after close() has already
  // restored focus, and that render replaces a table cell's opener. Look again
  // once it has run.
  restoreFocusAfterRender() {
    const handler = (event) => {
      document.removeEventListener("turbo:before-stream-render", handler)
      const render = event.detail.render
      event.detail.render = async (stream) => {
        await render(stream)
        requestAnimationFrame(() => this.restoreFocus())
      }
    }
    document.addEventListener("turbo:before-stream-render", handler)
    setTimeout(() => document.removeEventListener("turbo:before-stream-render", handler), 2000)
  }

  cancel() {
    this.dialogTarget.close()
  }

  restoreFocus() {
    let opener = this.opener
    // The stream may have replaced the opener (table cell); find its successor.
    if (opener && !opener.isConnected) {
      opener = this.element.querySelector(
        `[data-action~="user-list-completion#open"][data-item-id="${this.itemId}"][data-variant="${this.variant}"]`
      )
    }
    if (!opener) return
    // Refocusing a button inside the daisyUI menu would pop it open again.
    const dropdown = opener.closest(".dropdown")
    if (dropdown) dropdown.closest("[data-item-id]")?.focus({ preventScroll: true })
    else opener.focus({ preventScroll: true })
  }
}

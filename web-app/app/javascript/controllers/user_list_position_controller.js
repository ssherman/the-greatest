import { Controller } from "@hotwired/stimulus"

// One "Move to position…" dialog is shared by every row on the Edit page. The
// opener carries the item's id, title, position and the list size; they are
// written into the dialog just before it opens. The form is a Turbo form, so
// the server's stream answer morphs the rows. url holds "__ID__" for the item id.
export default class extends Controller {
  static targets = ["dialog", "form", "title", "current", "label", "input", "page"]
  static values = { url: String }

  open(event) {
    const opener = event.currentTarget
    const { itemId, itemTitle, position, max } = opener.dataset
    const row = opener.closest("[data-item-id][data-page]")

    this.formTarget.action = this.urlValue.replace("__ID__", itemId)
    // The edit controller reads this to put focus back on the moved row.
    this.formTarget.dataset.itemId = itemId
    if (row) this.pageTarget.value = row.dataset.page
    this.titleTarget.textContent = `Move “${itemTitle}”`
    this.currentTarget.textContent = `Currently #${position}`
    this.labelTarget.textContent = `New position (1–${max})`
    this.inputTarget.max = max
    this.inputTarget.value = ""
    this.dialogTarget.showModal()
    this.inputTarget.focus()
  }

  cancel() {
    this.dialogTarget.close()
  }

  submitted(event) {
    if (event.detail.success) this.dialogTarget.close()
  }
}

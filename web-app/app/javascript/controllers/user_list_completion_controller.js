import { Controller } from "@hotwired/stimulus"

// A single dialog is shared by every completion-date trigger on a list page.
// The trigger provides only the item id plus its display values; the form action
// and editable date are populated immediately before native dialog opens.
export default class extends Controller {
  static targets = ["dialog", "form", "title", "date", "variant"]

  open(event) {
    this.opener = event.currentTarget
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
    if (event.detail.success) this.dialogTarget.close()
  }

  cancel() {
    this.dialogTarget.close()
  }

  restoreFocus() {
    this.opener?.focus()
  }
}

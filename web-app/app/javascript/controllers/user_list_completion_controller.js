import { Controller } from "@hotwired/stimulus"

// A single dialog is shared by every completion-date trigger on a list page.
// The trigger provides only the item id plus its display values; the form action
// and editable date are populated immediately before native dialog opens.
export default class extends Controller {
  static targets = ["form", "title", "date"]

  connect() {
    this.restoreFocus = this.restoreFocus.bind(this)
  }

  open(event) {
    this.opener = event.currentTarget
    const { itemId, itemTitle, completedOn } = this.opener.dataset

    this.formTarget.action = `/user_list_items/${itemId}/completion`
    this.titleTarget.textContent = `Edit completion date for ${itemTitle}`
    this.dateTarget.value = completedOn || ""
    this.element.showModal()
    this.dateTarget.focus()
  }

  clear() {
    this.dateTarget.value = ""
    this.formTarget.requestSubmit()
  }

  cancel() {
    this.element.close()
  }

  restoreFocus() {
    this.opener?.focus()
  }
}

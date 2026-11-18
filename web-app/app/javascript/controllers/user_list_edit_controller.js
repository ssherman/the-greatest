import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// Drag-to-reorder on the Edit list page. The server answers every move with a
// Turbo Stream that morphs #edit-list-rows back to the truth, so this controller
// only reports the drop and renders whatever comes back.
// moveUrl holds "__ID__" in place of the item id.
export default class extends Controller {
  static targets = ["rows"]
  static values = { moveUrl: String, page: Number }

  // A morph keeps the container, but if the rows container is ever replaced
  // (e.g. empty list -> populated) Stimulus reconnects the target and we rebind.
  rowsTargetConnected(element) {
    this.sortable?.destroy()
    this.sortable = Sortable.create(element, {
      draggable: "[data-item-id]",
      handle: "[data-sortable-handle]",
      animation: 150,
      ghostClass: "opacity-50",
      onEnd: ({ item, oldIndex, newIndex }) => {
        if (oldIndex === newIndex) return
        // The moved row takes the stored position of the neighbour it displaced.
        const neighbour = newIndex > oldIndex ? item.previousElementSibling : item.nextElementSibling
        this.#submitMove(item.dataset.itemId, Number(neighbour.dataset.position))
      },
    })
  }

  rowsTargetDisconnected() {
    this.sortable?.destroy()
    this.sortable = null
  }

  disconnect() {
    this.sortable?.destroy()
    this.sortable = null
  }

  async #submitMove(itemId, position) {
    const body = new URLSearchParams({ "user_list_item[position]": position, page: this.pageValue })
    try {
      const response = await fetch(this.moveUrlValue.replace("__ID__", itemId), {
        method: "PATCH",
        headers: {
          Accept: "text/vnd.turbo-stream.html",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        body,
      })
      // Whatever the status, the body morphs the list back to the truth.
      Turbo.renderStreamMessage(await response.text())
    } catch {
      window.dispatchEvent(new CustomEvent("toast:show", {
        detail: { type: "error", message: "Couldn't save that move. Reload the page to see your list." },
      }))
    }
  }
}

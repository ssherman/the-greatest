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
    this.closeMenuOnSubmit = () => {
      // daisyUI keeps the menu open while a button inside it holds focus, and
      // morph keeps that focus on the moved row, so drop it when the form submits.
      const active = document.activeElement
      if (active?.closest?.(".dropdown")) active.blur()
    }
    element.addEventListener("turbo:submit-start", this.closeMenuOnSubmit)
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

  rowsTargetDisconnected(element) {
    element.removeEventListener("turbo:submit-start", this.closeMenuOnSubmit)
    this.sortable?.destroy()
    this.sortable = null
  }

  disconnect() {
    this.sortable?.destroy()
    this.sortable = null
  }

  async #submitMove(itemId, position) {
    const failed = () => window.dispatchEvent(new CustomEvent("toast:show", {
      detail: { type: "error", message: "Couldn't save that move. Reload the page to see your list." },
    }))
    // A second drop while this move is in flight would carry a stale position.
    this.sortable?.option("disabled", true)
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
      const text = await response.text()
      const isStream = (response.headers.get("Content-Type") || "").includes("turbo-stream") || text.includes("<turbo-stream")
      if (!isStream) return failed()
      // Whatever the status, a stream body morphs the list back to the truth.
      window.Turbo.renderStreamMessage(text)
      // Turbo renders stream elements after the next repaint; wait for them.
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
    } catch {
      failed()
    } finally {
      this.sortable?.option("disabled", false)
    }
  }
}

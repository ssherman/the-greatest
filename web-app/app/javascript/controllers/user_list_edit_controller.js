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
      draggable: "[data-item-id][tabindex='-1']",
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
    this.sortable?.destroy()
    this.sortable = null
  }

  connect() {
    this.element.addEventListener("turbo:submit-start", this.rememberRow)
    document.addEventListener("turbo:before-stream-render", this.focusAfterRender)
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-start", this.rememberRow)
    document.removeEventListener("turbo:before-stream-render", this.focusAfterRender)
    this.sortable?.destroy()
    this.sortable = null
  }

  // A menu or dialog write is about to morph the rows. Morph leaves focus on the
  // button the member pressed (which holds the daisyUI menu open), or loses it
  // when the row leaves the page, so remember the row and refocus it after the
  // render. The position dialog's form is outside any row and names its item.
  rememberRow = (event) => {
    const form = event.target
    const itemId = form.dataset?.itemId
    const row = form.closest?.("[data-item-id][tabindex='-1']") ||
      (itemId && this.element.querySelector(`[data-item-id="${itemId}"][tabindex='-1']`))
    this.pendingFocusId = row?.dataset.itemId || null
  }

  focusAfterRender = (event) => {
    if (!this.pendingFocusId || event.target.getAttribute("target") !== "edit-list-rows") return
    const id = this.pendingFocusId
    this.pendingFocusId = null
    const render = event.detail.render
    event.detail.render = async (stream) => {
      await render(stream)
      requestAnimationFrame(() => {
        const target = document.querySelector(`[data-item-id="${id}"][tabindex='-1']`) ||
          // The row left this page: fall back to the count heading.
          document.querySelector("#edit-list-rows [data-testid=item-count]")
        target?.focus({ preventScroll: true })
      })
    }
  }

  async #submitMove(itemId, position) {
    this.pendingFocusId = null
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

import { Controller } from "@hotwired/stimulus"
import { MAX_RATING, starFills, formatRating } from "./star_rating"

const STEP = 0.25
const KEY_DELTAS = { ArrowRight: STEP, ArrowUp: STEP, ArrowLeft: -STEP, ArrowDown: -STEP, PageUp: 1, PageDown: -1 }

// Quarter-star rating input (spec §5.1). One control for mouse, touch and
// keyboard: a mouse previews on hover and commits on press; a finger or pen
// commits where it lands and adjusts as it drags; keys step by a quarter.
// Writes the hidden review[rating] field and dispatches
// "reviews--star-input:change". The host sets a value with a "star-input:set"
// event on this element.
export default class extends Controller {
  static targets = ["slider", "star", "fill", "readout", "input"]

  connect() {
    this.committed = this.inputTarget.value === "" ? null : Number(this.inputTarget.value)
    this.dragging = false
    this.commit(this.committed, { silent: true })
  }

  set(event) {
    const value = event.detail?.value
    this.commit(value == null || value === "" ? null : Number(value))
  }

  press(event) {
    if (event.pointerType === "mouse" && event.button !== 0) return
    this.dragging = true
    // Keeps a drag that wanders off the row attached to it. Throws
    // NotFoundError for a pointer the browser no longer tracks; the drag
    // still works without capture, so that is not worth failing over.
    try {
      this.sliderTarget.setPointerCapture(event.pointerId)
    } catch {}
    this.commit(this.valueAt(event.clientX))
  }

  move(event) {
    if (this.dragging) {
      this.commit(this.valueAt(event.clientX))
    } else if (event.pointerType === "mouse") {
      this.paint(this.valueAt(event.clientX))
    }
  }

  release() {
    this.dragging = false
  }

  leave() {
    if (!this.dragging) this.paint(this.committed)
  }

  key(event) {
    let value
    if (event.key === "Home") value = STEP
    else if (event.key === "End") value = MAX_RATING
    else if (event.key in KEY_DELTAS) value = (this.committed ?? 0) + KEY_DELTAS[event.key]
    else return

    event.preventDefault()
    this.commit(Math.min(MAX_RATING, Math.max(STEP, value)))
  }

  // Star under the pointer, then the quarter of it, rounded up. A pointer in a
  // gap snaps to the end of the star before it; past either end clamps.
  valueAt(clientX) {
    const rects = this.starTargets.map((star) => star.getBoundingClientRect())
    for (let index = 0; index < rects.length; index++) {
      const rect = rects[index]
      if (clientX < rect.left) return index === 0 ? STEP : index
      if (clientX <= rect.right) {
        const quarters = Math.ceil(((clientX - rect.left) / rect.width) * 4)
        return index + Math.max(1, quarters) * STEP
      }
    }
    return MAX_RATING
  }

  commit(value, { silent = false } = {}) {
    this.committed = value
    this.inputTarget.value = value == null ? "" : formatRating(value)
    if (value == null) {
      this.sliderTarget.removeAttribute("aria-valuenow")
    } else {
      this.sliderTarget.setAttribute("aria-valuenow", String(value))
    }
    this.sliderTarget.setAttribute("aria-valuetext", value == null ? "Not rated" : `${formatRating(value)} stars`)
    this.paint(value)
    if (!silent) this.dispatch("change", { detail: { value } })
  }

  // Visual only: a hover preview must not change what a screen reader hears.
  paint(value) {
    const fills = starFills(value ?? 0)
    this.fillTargets.forEach((fill, index) => {
      fill.style.width = `${fills[index]}%`
    })
    this.readoutTarget.textContent = value == null ? "Not rated" : formatRating(value)
  }
}

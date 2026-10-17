import { Controller } from "@hotwired/stimulus"

const DEBOUNCE_MS = 250
const MIN_LENGTH = 2 // mirrors Books::BrowseQuery::SEARCH_MIN_LENGTH

// Connects to data-controller="books--category-search"
//
// The form already works without JavaScript: Enter does a GET into the results
// frame. This only adds the submit-as-you-type, so the server stays the single
// source of what a search returns.
export default class extends Controller {
  static targets = ["announcer"]
  static values = { frame: String, browseUrl: String }

  connect() {
    this.timer = null
    this.submission = null
    // A box that already holds text means results are on screen: Back restores
    // a Turbo snapshot (cloneNode keeps the input's value) and a search URL
    // can be opened directly. Starting from false there would leave those
    // results under an emptied box with nothing to bring the grid back.
    this.searched = this.element.elements.q.value.trim().length > 0
    // The snapshot also cloned the last result count into the announcer, which
    // would read as stale news the next time the region is touched.
    if (this.hasAnnouncerTarget) this.announcerTarget.textContent = ""

    this.onFrameLoad = this.announce.bind(this)
    this.onSubmitStart = (event) => { this.submission = event.detail.formSubmission }
    this.onSubmitEnd = () => { this.submission = null }
    // Listen on the document rather than the frame: the frame can be swapped
    // out by a Turbo visit, and turbo:frame-load bubbles to here either way.
    document.addEventListener("turbo:frame-load", this.onFrameLoad)
    this.element.addEventListener("turbo:submit-start", this.onSubmitStart)
    this.element.addEventListener("turbo:submit-end", this.onSubmitEnd)
  }

  disconnect() {
    clearTimeout(this.timer)
    document.removeEventListener("turbo:frame-load", this.onFrameLoad)
    this.element.removeEventListener("turbo:submit-start", this.onSubmitStart)
    this.element.removeEventListener("turbo:submit-end", this.onSubmitEnd)
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.run(), DEBOUNCE_MS)
  }

  // Runs for typed searches (via requestSubmit) and for Enter alike. Cancel the
  // pending debounce so it cannot fire a second identical request, and
  // remember that results are on screen so clearing the box can bring the grid
  // back.
  //
  // Dropping the frame's src also cancels a grid restore still in flight (Turbo
  // aborts the frame's fetch when its sourceURL goes away). Without it, a slow
  // grid response could land after this search and replace its results.
  submitted() {
    clearTimeout(this.timer)
    this.frame?.removeAttribute("src")
    this.searched = true
  }

  run() {
    const value = this.element.elements.q.value.trim()

    if (value.length >= MIN_LENGTH) {
      this.element.requestSubmit()
    } else if (value.length === 0 && this.searched) {
      // The grid response is the full edge-cached page; Turbo lifts just the
      // matching frame out of it. Never before a search has run: the grid is
      // already showing, and reloading it would only flash it.
      this.searched = false
      // A restore and a search only cancel their own kind, so stop a search
      // still in flight: its uncached response could otherwise land after the
      // grid and put results back under an empty box.
      this.submission?.stop()
      this.submission = null
      // Removing src first guarantees a fresh load (and cancels any earlier
      // restore) instead of relying on the attribute having changed.
      this.frame.removeAttribute("src")
      this.frame.src = this.browseUrlValue
    }
    // One character: too short to search and not empty enough to restore, so
    // leave whatever is showing alone rather than flicker between the two.
  }

  // An aria-live region inserted already holding its text is usually not
  // announced, and every swap inserts a fresh one. So the frame's own status
  // is plain text, and this copies it into the one region that persists.
  announce(event) {
    if (event.target.id !== this.frameValue || !this.hasAnnouncerTarget) return

    const status = event.target.querySelector("[data-search-status]")
    this.announcerTarget.textContent = status ? status.textContent.trim() : ""
  }

  get frame() {
    return document.getElementById(this.frameValue)
  }
}

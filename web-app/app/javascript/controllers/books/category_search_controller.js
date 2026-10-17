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
    this.searched = false
    this.onFrameLoad = this.announce.bind(this)
    // Listen on the document rather than the frame: the frame can be swapped
    // out by a Turbo visit, and turbo:frame-load bubbles to here either way.
    document.addEventListener("turbo:frame-load", this.onFrameLoad)
  }

  disconnect() {
    clearTimeout(this.timer)
    document.removeEventListener("turbo:frame-load", this.onFrameLoad)
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.run(), DEBOUNCE_MS)
  }

  // Enter submits the form natively. Cancel the pending debounce so it cannot
  // fire a second identical request, and remember that results are on screen
  // so clearing the box can bring the grid back.
  submitted() {
    clearTimeout(this.timer)
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
      // Drop the attribute first: Turbo ignores an assignment that leaves
      // src unchanged, and a frame already pointing at the grid (restored
      // once before) would otherwise keep showing the old search results.
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

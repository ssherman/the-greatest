import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="books--nav-drawer"
//
// daisyUI's drawer is pure CSS: a hidden checkbox holds the open/closed state
// and a <label> toggles it. That works with JavaScript disabled, which is why
// this controller augments it rather than replacing it. Four gaps are left:
//
//   1. Turbo caches the checkbox CHECKED. PageSnapshot#clone is cloneNode(true),
//      and the HTML standard propagates an input's checkedness into the clone.
//      Open the drawer, follow a link, press Back: the drawer is restored open
//      AND the page behind is scroll-locked, because daisyUI keys its lock off
//      :root:has(.drawer-toggle:checked). This is the one that bites users.
//   2. Escape does not close it.
//   3. Focus is not contained -- tabbing past the last panel link walks into
//      page content hidden behind the overlay.
//   4. `display:none` does not clear `:checked`, so crossing the lg breakpoint
//      while open strands the panel over the desktop layout. The `lg:hidden`
//      on .drawer-side handles the visual half; this handles the state.
//
// Forward navigation needs no help: Turbo replaces <body> with freshly parsed
// HTML, and a morph refresh syncs the checkbox property from the new document.
const DESKTOP = "(min-width: 64rem)" // Tailwind `lg`

export default class extends Controller {
  static targets = ["toggle", "content", "button"]

  connect() {
    this.close()

    this.onKeydown = this.onKeydown.bind(this)
    this.onBeforeCache = this.close.bind(this)
    this.onToggleChange = this.syncState.bind(this)
    this.onBreakpointChange = this.onBreakpointChange.bind(this)

    document.addEventListener("keydown", this.onKeydown)
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
    this.toggleTarget.addEventListener("change", this.onToggleChange)

    this.desktop = window.matchMedia(DESKTOP)
    this.desktop.addEventListener("change", this.onBreakpointChange)

    this.syncState()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("turbo:before-cache", this.onBeforeCache)
    this.toggleTarget.removeEventListener("change", this.onToggleChange)
    this.desktop.removeEventListener("change", this.onBreakpointChange)
    // Leave no inert wrapper behind if we are torn down while open.
    this.contentTarget.removeAttribute("inert")
  }

  // Close when a link inside the panel is clicked. Forward navigation would
  // reset the checkbox anyway, but this gives immediate feedback and covers
  // links that never swap the body: in-page anchors and Turbo frame targets.
  closeOnNavigate(event) {
    if (event.target.closest("a")) this.close()
  }

  close() {
    if (this.hasToggleTarget) this.toggleTarget.checked = false
    this.syncState()
  }

  onKeydown(event) {
    if (event.key === "Escape" && this.isOpen) this.close()
  }

  onBreakpointChange(event) {
    if (event.matches) this.close()
  }

  get isOpen() {
    return this.hasToggleTarget && this.toggleTarget.checked
  }

  // Single place that mirrors checkbox state onto the things CSS cannot reach:
  // the label's aria-expanded, and `inert` on the background content.
  syncState() {
    const open = this.isOpen

    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", open ? "true" : "false")
    }

    if (this.hasContentTarget) {
      if (open) {
        this.contentTarget.setAttribute("inert", "")
      } else {
        this.contentTarget.removeAttribute("inert")
      }
    }
  }
}

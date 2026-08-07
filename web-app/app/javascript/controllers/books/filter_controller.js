import { Controller } from "@hotwired/stimulus"

const DEBOUNCE_MS = 250

// Connects to data-controller="books--filter"
export default class extends Controller {
  static targets = ["level", "summary", "pane", "results", "selected", "browse", "capNotice", "query", "year"]
  static values = { maxCategories: Number, maxCountries: Number }

  connect() {
    this.timers = {}
    this.pendingSearches = {}
    this.currentLevel = "root"
    this.dialog = this.element.closest("dialog")
    this.discardBound = this.discard.bind(this)
    this.dialog?.addEventListener("close", this.discardBound)
    this.show("root")
    this.refresh()
  }

  disconnect() {
    this.dialog?.removeEventListener("close", this.discardBound)
  }

  open(event) {
    this.show(event.currentTarget.dataset.levelTarget)
  }

  back() {
    this.show("root")
  }

  cancel() {
    this.dialog?.close()
  }

  show(level) {
    const previousLevel = this.currentLevel
    this.currentLevel = level
    this.levelTargets.forEach((el) => el.classList.toggle("hidden", el.dataset.level !== level))
    this.dialog?.setAttribute("aria-labelledby", `books_filter_modal_heading_${level}`)

    if (level === "root") {
      this.focusRootButton(previousLevel)
      return
    }

    const pane = this.paneTargets.find((el) => el.dataset.axis === level)
    if (pane && !pane.src && pane.dataset.paneSrc) pane.src = pane.dataset.paneSrc

    this.focusEnteringLevel(level)
  }

  // Moving between panes hides the level the user was just looking at via
  // display:none, which drops document.activeElement to <body>. Sending focus
  // into the entering level keeps a keyboard user's place and gives a
  // screen-reader user a signal the dialog's contents changed.
  //
  // discard() runs on the dialog's "close" event and ends with show("root").
  // DaisyUI keeps the dialog focusable through its ~300ms fade-out, so focusing
  // a button inside it here would override the browser's restoration of focus
  // to the Filters trigger and strand a keyboard user at <body>.
  focusRootButton(level) {
    if (!this.dialog?.open) return

    this.element.querySelector(`[data-action~="books--filter#open"][data-level-target="${level}"]`)?.focus()
  }

  focusEnteringLevel(level) {
    const query = this.queryTargets.find((el) => el.dataset.axis === level)
    if (query) {
      query.focus()
      return
    }

    this.levelTargets.find((el) => el.dataset.level === level)?.querySelector("input")?.focus()
  }

  search(event) {
    const axis = event.currentTarget.dataset.axis
    const query = event.currentTarget.value.trim()

    clearTimeout(this.timers[axis])
    this.timers[axis] = setTimeout(() => this.runSearch(axis, query), DEBOUNCE_MS)
  }

  // The search inputs live inside the form that submits to /filters, so Enter
  // would apply the staged filters mid-search. On a phone the keyboard's
  // Search key IS Enter, so this is the common path, not an edge case.
  suppressEnter(event) {
    if (event.key === "Enter") event.preventDefault()
  }

  // The search input is server-rendered and usable the instant the modal
  // opens, but its axis's results frame doesn't exist in the DOM until the
  // pane's own turbo-frame finishes loading. A query typed inside that window
  // (trivially reachable on a slow connection, since the debounce is only
  // 250ms) would otherwise be silently dropped -- the input keeps the typed
  // text but nothing ever runs it. Queueing it here and flushing from
  // frameLoaded() once the frame lands means it still runs instead of
  // vanishing.
  runSearch(axis, query) {
    const frame = this.resultsTargets.find((el) => el.dataset.axis === axis)
    if (!frame) {
      this.pendingSearches[axis] = query
      return
    }

    const base = frame.dataset.resultsSrc
    const separator = base.includes("?") ? "&" : "?"
    frame.src = `${base}${separator}q=${encodeURIComponent(query)}`
  }

  // A search hit and a browsed row can name the same value. Checking the search
  // hit adopts the existing row when there is one, and otherwise moves the label
  // out of the results frame -- which the next search would otherwise discard.
  // Both the adopt (remove) and move (appendChild) mutations are deferred to a
  // requestAnimationFrame: mutating the node that dispatched the very "change"
  // event we're handling, before the browser has finished dispatching it, is
  // fragile regardless of who's driving the page. On the adopt path, focus
  // moves to the twin before the search row is removed -- removing a focused
  // element sends focus to <body>, which for a keyboard or screen-reader user
  // drops them back to the top of the page mid-interaction. twin.checked is
  // set synchronously, so a check immediately followed by an uncheck (both
  // landing before the next frame) would otherwise leave the twin checked
  // against the user's final intent -- each deferred callback re-reads
  // input.checked and bails if it no longer matches, undoing twin.checked too
  // on the adopt path since that's the side effect nothing else would revert.
  toggle(event) {
    const input = event.target
    const label = input.closest("label")
    const results = label?.closest("[data-books--filter-target='results']")

    if (results && input.checked) {
      const twin = this.findTwin(input, results)
      if (twin) {
        twin.checked = true
        requestAnimationFrame(() => {
          if (!input.checked) {
            twin.checked = false
            return
          }
          twin.focus()
          label.remove()
          this.refresh()
        })
      } else {
        requestAnimationFrame(() => {
          if (!input.checked) return
          label.dataset.staged = "true"
          this.selectedFor(input.dataset.axis)?.appendChild(label)
          this.refresh()
        })
      }
      return
    }

    this.refresh()
  }

  findTwin(input, results) {
    const matches = this.element.querySelectorAll(
      `input[name="${input.name}"][value="${CSS.escape(input.value)}"]`
    )
    return Array.from(matches).find((el) => el !== input && !results.contains(el))
  }

  selectedFor(axis) {
    return this.selectedTargets.find((el) => el.dataset.axis === axis)
  }

  // A pane's cap notice arrives with its frame, well after connect() has
  // already run refresh() once. Without this, checking up to the cap inside a
  // pane that just loaded leaves the browse rows enabled past the limit until
  // some unrelated event happens to call refresh() again.
  capNoticeTargetConnected() {
    this.refresh()
  }

  // turbo:frame-load bubbles (and is composed), and both the pane frame
  // itself and the results frame nested inside it fire it, so the single
  // listener on the pane frame (see the component template) catches a
  // first-time pane load AND every search response. refresh() has to run on
  // both: capNoticeTargetConnected() only fires once, when the pane's own
  // frame first loads, but a search swaps in fresh, unchecked checkboxes
  // inside the results frame that nothing else ever re-disables at the cap --
  // skipped here, a user could check past maxCategories/maxCountries and get
  // a bare 404 from Books::FilterParams on Apply. Reading
  // event.target.dataset.axis rather than a fixed axis lets one handler serve
  // both panes. The pending-search dequeue in runSearch() already deletes the
  // queue entry before assigning frame.src, so replaying it here from the
  // frame-load it itself triggers cannot loop.
  frameLoaded(event) {
    this.refresh()

    const axis = event.target.dataset.axis
    const query = this.pendingSearches[axis]
    if (query === undefined) return

    delete this.pendingSearches[axis]
    this.runSearch(axis, query)
  }

  // Cancel, Escape, and backdrop-click all end up here via the dialog's native
  // "close" event, so staged state is discarded identically no matter how the
  // dialog closed. form.reset() alone is not enough: a checked search hit that
  // got hoisted into the selected container is a DOM move, not just a value
  // change, so reset() would leave it sitting there unchecked instead of gone.
  discard() {
    // A query queued while its pane was still loading must not outlive the
    // dialog it was typed into -- otherwise the frame arriving after Cancel
    // would still fire the search once it loads, after everything else has
    // already been discarded. Clearing the queue alone is not enough: a
    // debounce timer that has not fired yet would re-populate it afterwards.
    Object.values(this.timers).forEach((timer) => clearTimeout(timer))
    this.timers = {}
    this.pendingSearches = {}

    this.selectedTargets.forEach((container) => {
      container.querySelectorAll("[data-staged]").forEach((label) => label.remove())
    })

    this.element.querySelector("form")?.reset()
    this.queryTargets.forEach((input) => { input.value = "" })
    this.resultsTargets.forEach((frame) => { frame.innerHTML = "" })

    this.refresh()
    this.show("root")
  }

  refresh() {
    this.applyAxis("category", this.maxCategoriesValue)
    this.applyAxis("country", this.maxCountriesValue)
    this.refreshYearSummary()
  }

  applyAxis(axis, max) {
    const inputs = Array.from(this.element.querySelectorAll(`input[type="checkbox"][data-axis="${axis}"]`))
    // An unopened pane has no browse/results checkboxes yet, but applied
    // selections are hoisted into the modal itself and are always present, so
    // this only stays empty when nothing is applied and nothing is staged.
    if (inputs.length === 0) return

    const checked = inputs.filter((el) => el.checked)
    const atCap = max > 0 && checked.length >= max

    inputs.forEach((el) => { el.disabled = !el.checked && atCap })

    const notice = this.capNoticeTargets.find((el) => el.dataset.axis === axis)
    if (notice) {
      notice.textContent = atCap ? `You can select up to ${max}. Uncheck one to add another.` : ""
      notice.classList.toggle("hidden", !atCap)
    }

    const summary = this.summaryTargets.find((el) => el.dataset.axis === axis)
    if (summary) {
      const names = checked.map((el) => el.closest("label")?.querySelector(".label-text")?.textContent.trim())
      summary.textContent = names.filter(Boolean).join(", ") || "Any"
    }
  }

  refreshYearSummary() {
    const summary = this.summaryTargets.find((el) => el.dataset.axis === "year")
    if (!summary) return

    const [start, end] = this.yearTargets.map((el) => el.value.trim())
    summary.textContent = this.yearLabel(start, end)
  }

  yearLabel(start, end) {
    if (start && end) return start === end ? start : `${start}–${end}`
    if (start) return `Since ${start}`
    if (end) return `To ${end}`
    return "Any"
  }
}

import { Controller } from "@hotwired/stimulus"

const SEARCH_DEBOUNCE_MS = 250
const COUNT_DEBOUNCE_MS = 300
const CATEGORY_TYPES = ["genre", "audience", "subject", "location"]

// Connects to data-controller="books--filter"
//
// The one rule this controller is built around: a checkbox the reader ticks is
// never moved, re-parented or focused. The old panel hoisted a ticked search
// hit into a "selected" container, or focused its twin in the browse list, and
// either one made the list jump under the reader's finger.
//
// So the checkboxes hold no state. The hidden inputs in the store target are
// the selection (they are also what the form submits), toggle() edits only the
// store, and sync() derives every checkbox, chip, summary and cap from it. A
// row that arrives later (a lazy page, a search result) is simply synced, which
// is why an applied filter that turns up in a search shows as ticked.
export default class extends Controller {
  static targets = [
    "store", "level", "scroll", "summary", "query", "chips", "pane", "results",
    "yearPreset", "year", "capNotice", "submit"
  ]

  static values = { maxCategories: Number, maxCountries: Number, countUrl: String, initialCount: Number }

  connect() {
    this.searchTimers = {}
    this.pendingSearches = {}
    this.countTimer = null
    this.countRequest = null
    this.currentLevel = "root"
    this.dialog = this.element.closest("dialog")
    this.form = this.element.querySelector("form")

    // What the page was rendered with. Closing the panel without Show puts
    // this back, however much was ticked, cleared or searched in between.
    this.storeSnapshot = this.storeTarget.innerHTML
    this.yearSnapshot = this.yearTargets.map((el) => el.value)
    this.initialQuery = this.formQuery()
    this.countedQuery = this.initialQuery

    this.discardBound = this.discard.bind(this)
    this.dialog?.addEventListener("close", this.discardBound)
    // Turbo snapshots the page for its back/forward cache. Without this, a
    // reader who ticks things and then follows a link would come back to a
    // panel full of picks they never applied.
    document.addEventListener("turbo:before-cache", this.discardBound)

    this.sync()
  }

  disconnect() {
    this.dialog?.removeEventListener("close", this.discardBound)
    document.removeEventListener("turbo:before-cache", this.discardBound)
    this.cancelTimers()
    this.countRequest?.abort()
  }

  // --- moving between pages -------------------------------------------------

  open(event) {
    const level = event.currentTarget.dataset.levelTarget
    this.show(level)

    const pane = this.paneFor(level)
    if (pane && !pane.src && pane.dataset.paneSrc) pane.src = pane.dataset.paneSrc

    // Focus on *entering* a page is fine: nothing has been ticked on it yet.
    // Hiding the page the reader was on drops focus to <body>; this keeps a
    // keyboard user's place and tells a screen reader the contents changed.
    const levelEl = this.levelFor(level)
    const target = this.queryFor(level) || levelEl?.querySelector("[data-action~='books--filter#back']")
    target?.focus()
  }

  back() {
    const previous = this.currentLevel
    this.show("root")

    // discard() also lands on root, from the dialog's "close" event. DaisyUI
    // keeps the dialog focusable through its fade-out, so focusing in here then
    // would override the browser's return of focus to the Filter button.
    if (!this.dialog?.open) return
    this.element.querySelector(`[data-action~="books--filter#open"][data-level-target="${previous}"]`)?.focus()
  }

  show(level) {
    this.currentLevel = level
    this.levelTargets.forEach((el) => { el.hidden = el.dataset.level !== level })
    this.dialog?.setAttribute("aria-labelledby", `books_filter_modal_heading_${level}`)
    // One scroll region serves every page; a new page starts at its top.
    if (this.hasScrollTarget) this.scrollTarget.scrollTop = 0
    this.syncCapNotice()
  }

  // --- the selection ----------------------------------------------------------

  toggle(event) {
    const box = event.currentTarget
    const { axis, slug } = box.dataset
    const entry = this.entryFor(axis, slug)

    if (box.checked && !entry) {
      // disabled stops this at the cap, but a search result can land and be
      // ticked in the moment before frameLoaded() syncs it.
      if (this.atCap(axis)) {
        box.checked = false
        return
      }
      this.storeTarget.appendChild(this.buildEntry(box.dataset))
    } else if (!box.checked && entry) {
      entry.remove()
    }

    this.sync()
  }

  removeChip(event) {
    const button = event.currentTarget
    const strip = button.closest("[data-books--filter-target='chips']")
    const index = Array.from(strip.querySelectorAll("button")).indexOf(button)

    this.entryFor(button.dataset.axis, button.dataset.slug)?.remove()
    this.sync()

    // A click from a pointer can leave focus where it was. A keyboard press
    // (detail 0) on a button that no longer exists would drop the reader at
    // <body>, so hand focus to the neighbouring chip, or the search box.
    if (event.detail !== 0) return
    const rest = strip.querySelectorAll("button")
    const next = rest[Math.min(index, rest.length - 1)] || this.queryFor(strip.dataset.type)
    next?.focus({ preventScroll: true })
  }

  clear() {
    this.storeTarget.replaceChildren()
    this.yearTargets.forEach((el) => { el.value = "" })
    this.sync()
  }

  pickYears(event) {
    const { start, end } = event.currentTarget.dataset
    this.yearInput("year_start").value = start || ""
    this.yearInput("year_end").value = end || ""
    this.sync()
  }

  yearsChanged() {
    this.sync()
  }

  // Cancel, Escape and a backdrop click all close the dialog, and closing
  // always lands here, so unapplied work is thrown away the same way however
  // the reader left.
  discard() {
    this.cancelTimers()
    this.countRequest?.abort()
    this.countRequest = null

    this.storeTarget.innerHTML = this.storeSnapshot
    this.yearTargets.forEach((el, i) => { el.value = this.yearSnapshot[i] ?? "" })

    this.queryTargets.forEach((input) => { input.value = "" })
    this.element.querySelectorAll("[data-filter-row][hidden]").forEach((row) => { row.hidden = false })
    this.element.querySelectorAll("[data-filter-no-matches]").forEach((line) => { line.hidden = true })
    this.resultsTargets.forEach((frame) => this.emptyResults(frame))

    this.countedQuery = this.initialQuery
    this.submitTarget.textContent = this.showLabel(this.initialCountValue)

    this.sync()
    this.show("root")
  }

  // Everything visible is derived from the store here. It sets properties and
  // text only: it never moves, re-parents or focuses a checkbox.
  sync() {
    const entries = this.entries()
    const selected = new Set(entries.map((entry) => this.key(entry.dataset.axis, entry.value)))
    const capped = { category: this.atCap("category"), country: this.atCap("country") }

    this.element.querySelectorAll("input[type='checkbox'][data-filter-option]").forEach((box) => {
      const on = selected.has(this.key(box.dataset.axis, box.dataset.slug))
      const disabled = !on && capped[box.dataset.axis]
      if (box.checked !== on) box.checked = on
      if (box.disabled !== disabled) box.disabled = disabled
    })

    this.syncCapNotice()
    this.chipsTargets.forEach((strip) => this.syncChips(strip, entries))
    this.syncSummaries(entries)
    this.syncYearPresets()
    this.scheduleCount()
  }

  // One notice in the footer serves every page, so it speaks for the page in
  // view: Origin's cap on Origin, the shared category cap on a category page.
  // The first page and Published name whichever cap is reached.
  syncCapNotice() {
    if (!this.hasCapNoticeTarget) return

    let axis = null
    if (this.currentLevel === "country") axis = "country"
    else if (CATEGORY_TYPES.includes(this.currentLevel)) axis = "category"
    else axis = ["category", "country"].find((candidate) => this.atCap(candidate)) || null

    const text = axis && this.atCap(axis)
      ? `You can select up to ${this.maxFor(axis)}. Untick one to add another.`
      : ""
    if (this.capNoticeTarget.textContent !== text) this.capNoticeTarget.textContent = text
  }

  // Chips live in a fixed-height strip outside the lists, so adding one
  // cannot push a row. They are rebuilt only when the selection for their
  // type actually changed, so an unrelated sync leaves a focused chip alone.
  syncChips(strip, entries) {
    const mine = entries.filter((entry) => entry.dataset.axis === "category" && entry.dataset.type === strip.dataset.type)
    const signature = mine.map((entry) => entry.value).join("\n")
    if (strip.dataset.signature === signature) return
    strip.dataset.signature = signature

    strip.replaceChildren(...mine.map((entry) => this.buildChip(entry)))
  }

  syncSummaries(entries) {
    this.summaryTargets.forEach((summary) => {
      const type = summary.dataset.type
      if (type === "year") {
        summary.textContent = this.yearLabel(this.yearInput("year_start").value.trim(), this.yearInput("year_end").value.trim())
        return
      }

      const names = entries
        .filter((entry) => entry.dataset.type === type)
        .map((entry) => entry.dataset.name)
      summary.textContent = names.join(", ") || "Any"
    })
  }

  // A preset reads as pressed only when the boxes hold exactly its range, so
  // editing a box by hand un-presses it. Fill versus outline as well as
  // aria-pressed: the state must not rest on colour alone.
  syncYearPresets() {
    const start = this.yearInput("year_start")?.value.trim() ?? ""
    const end = this.yearInput("year_end")?.value.trim() ?? ""

    this.yearPresetTargets.forEach((button) => {
      const on = (button.dataset.start || "") === start && (button.dataset.end || "") === end
      button.setAttribute("aria-pressed", on ? "true" : "false")
      button.classList.toggle("btn-primary", on)
      button.classList.toggle("btn-outline", !on)
    })
  }

  yearLabel(start, end) {
    if (start && end) return start === end ? start : `${start}–${end}`
    if (start) return `Since ${start}`
    if (end) return `To ${end}`
    return "Any"
  }

  // --- searching -------------------------------------------------------------

  query(event) {
    const input = event.currentTarget
    const type = input.dataset.type

    if (input.dataset.mode === "search") {
      clearTimeout(this.searchTimers[type])
      const term = input.value.trim()
      this.searchTimers[type] = setTimeout(() => this.runSearch(type, term), SEARCH_DEBOUNCE_MS)
    } else {
      this.filterRows(type, input.value)
    }
  }

  // Genre and Origin ship their whole list, so the box just hides rows. A
  // hidden row that is ticked stays in the store, so it is still submitted.
  filterRows(type, raw) {
    const pane = this.paneFor(type)
    if (!pane) return

    const term = raw.trim().toLowerCase()
    const rows = pane.querySelectorAll("[data-filter-row]")
    let shown = 0
    rows.forEach((row) => {
      const match = !term || (row.dataset.filterText || "").includes(term)
      row.hidden = !match
      if (match) shown += 1
    })

    const none = pane.querySelector("[data-filter-no-matches]")
    if (none) none.hidden = !(rows.length > 0 && shown === 0)
  }

  // The search box is usable the moment its page opens, but the results frame
  // it fills only exists once the page's own frame has loaded. A query typed
  // in that window is queued here and run from frameLoaded(), rather than
  // silently dropped with the text still sitting in the box.
  runSearch(type, term) {
    delete this.searchTimers[type]

    const frame = this.resultsFor(type)
    if (!frame) {
      this.pendingSearches[type] = term
      return
    }
    delete this.pendingSearches[type]

    if (!term) {
      this.emptyResults(frame)
      return
    }

    const base = frame.dataset.resultsSrc
    const separator = base.includes("?") ? "&" : "?"
    frame.src = `${base}${separator}q=${encodeURIComponent(term)}`
  }

  // The search inputs sit inside the form that submits to /filters, so Enter
  // would apply the selection mid-search. On a phone the keyboard's Search key
  // IS Enter, so this is the common path, not an edge case.
  suppressEnter(event) {
    if (event.key === "Enter") event.preventDefault()
  }

  // turbo:frame-load bubbles, so the one listener on each page frame hears the
  // page's own first load and every search inside it. Both bring checkboxes
  // that have never been synced: unticked, and not disabled at the cap.
  frameLoaded(event) {
    const frame = event.target
    const type = frame.dataset.type

    // Clearing a search does not cancel one already in flight; if it lands
    // after the box was emptied (or the panel closed), throw it away.
    if (this.resultsTargets.includes(frame) && !this.queryFor(type)?.value.trim()) {
      this.emptyResults(frame)
    }

    const input = this.queryFor(type)
    if (input?.dataset.mode === "filter" && input.value.trim()) this.filterRows(type, input.value)

    this.sync()

    const pending = this.pendingSearches[type]
    if (pending === undefined) return
    // runSearch() deletes the queue entry before it sets src, so the load that
    // src triggers cannot replay it again.
    this.runSearch(type, pending)
  }

  emptyResults(frame) {
    frame.removeAttribute("src")
    frame.replaceChildren()
  }

  // --- the Show button count -------------------------------------------------

  scheduleCount() {
    if (!this.form || !this.hasCountUrlValue) return

    clearTimeout(this.countTimer)
    this.countTimer = setTimeout(() => this.runCount(), COUNT_DEBOUNCE_MS)
  }

  // The button keeps its last number until a newer one arrives; a failed or
  // superseded request leaves it alone rather than blanking it.
  runCount() {
    this.countTimer = null
    const query = this.formQuery()
    if (this.countRequest && query === this.requestedQuery) return

    this.countRequest?.abort()
    this.countRequest = null
    if (query === this.countedQuery) return

    const request = new AbortController()
    this.countRequest = request
    this.requestedQuery = query

    fetch(`${this.countUrlValue}?${query}`, { signal: request.signal, headers: { Accept: "application/json" } })
      .then((response) => (response.ok ? response.json() : null))
      .then((data) => {
        if (!data || this.countRequest !== request) return
        this.countedQuery = query
        this.submitTarget.textContent = this.showLabel(data.count)
      })
      .catch(() => {})
      .finally(() => {
        if (this.countRequest === request) this.countRequest = null
      })
  }

  formQuery() {
    return this.form ? new URLSearchParams(new FormData(this.form)).toString() : ""
  }

  showLabel(count) {
    const n = Number(count)
    return `Show ${n.toLocaleString("en-US")} ${n === 1 ? "book" : "books"}`
  }

  // --- helpers ---------------------------------------------------------------

  entries() {
    return Array.from(this.storeTarget.querySelectorAll("input[data-store-entry]"))
  }

  entryFor(axis, slug) {
    return this.entries().find((entry) => entry.dataset.axis === axis && entry.value === slug)
  }

  buildEntry({ axis, slug, type, name }) {
    const entry = document.createElement("input")
    entry.type = "hidden"
    entry.name = axis === "country" ? "country_slugs[]" : "category_slugs[]"
    entry.setAttribute("value", slug)
    entry.setAttribute("data-store-entry", "")
    entry.dataset.axis = axis
    entry.dataset.type = type
    entry.dataset.name = name
    return entry
  }

  buildChip(entry) {
    const chip = document.createElement("span")
    chip.className = "badge badge-lg gap-1 shrink-0 whitespace-nowrap"
    chip.append(entry.dataset.name)

    const button = document.createElement("button")
    button.type = "button"
    button.className = "font-bold cursor-pointer"
    button.setAttribute("aria-label", `Remove ${entry.dataset.name}`)
    button.dataset.action = "books--filter#removeChip"
    button.dataset.axis = entry.dataset.axis
    button.dataset.slug = entry.value
    button.textContent = "×"
    chip.append(button)
    return chip
  }

  key(axis, slug) {
    return `${axis}:${slug}`
  }

  maxFor(axis) {
    return axis === "country" ? this.maxCountriesValue : this.maxCategoriesValue
  }

  // Categories share one cap across Genre, Audience, Subject and Setting, so
  // a pick on one page can disable rows on another.
  atCap(axis) {
    const max = this.maxFor(axis)
    return max > 0 && this.entries().filter((entry) => entry.dataset.axis === axis).length >= max
  }

  levelFor(level) {
    return this.levelTargets.find((el) => el.dataset.level === level)
  }

  paneFor(type) {
    return this.paneTargets.find((el) => el.dataset.type === type)
  }

  resultsFor(type) {
    return this.resultsTargets.find((el) => el.dataset.type === type)
  }

  queryFor(type) {
    return this.queryTargets.find((el) => el.dataset.type === type)
  }

  yearInput(name) {
    return this.yearTargets.find((el) => el.name === name)
  }

  cancelTimers() {
    Object.values(this.searchTimers).forEach((timer) => clearTimeout(timer))
    this.searchTimers = {}
    this.pendingSearches = {}
    clearTimeout(this.countTimer)
    this.countTimer = null
  }
}

import { Controller } from "@hotwired/stimulus"

const DEBOUNCE_MS = 250

// Connects to data-controller="books--filter"
export default class extends Controller {
  static targets = ["level", "summary", "pane", "results", "selected", "browse", "capNotice", "query", "year"]
  static values = { maxCategories: Number, maxCountries: Number }

  connect() {
    this.timers = {}
    this.show("root")
    this.refresh()
  }

  open(event) {
    this.show(event.currentTarget.dataset.levelTarget)
  }

  back() {
    this.show("root")
  }

  cancel() {
    this.element.closest("dialog")?.close()
  }

  show(level) {
    this.levelTargets.forEach((el) => el.classList.toggle("hidden", el.dataset.level !== level))
    if (level === "root") return

    const pane = this.paneTargets.find((el) => el.dataset.axis === level)
    if (pane && !pane.src && pane.dataset.paneSrc) pane.src = pane.dataset.paneSrc
  }

  search(event) {
    const axis = event.currentTarget.dataset.axis
    const query = event.currentTarget.value.trim()

    clearTimeout(this.timers[axis])
    this.timers[axis] = setTimeout(() => this.runSearch(axis, query), DEBOUNCE_MS)
  }

  runSearch(axis, query) {
    const frame = this.resultsTargets.find((el) => el.dataset.axis === axis)
    if (!frame) return

    const base = frame.dataset.resultsSrc
    const separator = base.includes("?") ? "&" : "?"
    frame.src = `${base}${separator}q=${encodeURIComponent(query)}`
  }

  // A search hit and a browsed row can name the same value. Checking the search
  // hit adopts the existing row when there is one, and otherwise moves the label
  // out of the results frame -- which the next search would otherwise discard.
  toggle(event) {
    const input = event.target
    const label = input.closest("label")
    const results = label?.closest("[data-books--filter-target='results']")

    if (results && input.checked) {
      const twin = this.findTwin(input, results)
      if (twin) {
        twin.checked = true
        label.remove()
      } else {
        this.selectedFor(input.dataset.axis)?.appendChild(label)
      }
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

  refresh() {
    this.applyAxis("category", this.maxCategoriesValue)
    this.applyAxis("country", this.maxCountriesValue)
    this.refreshYearSummary()
  }

  applyAxis(axis, max) {
    const inputs = Array.from(this.element.querySelectorAll(`input[data-axis="${axis}"]`))
    // An unopened pane has no inputs yet. Bailing keeps the server-rendered
    // summary, which is correct; recomputing from zero inputs would blank it.
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

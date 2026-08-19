import { Controller } from "@hotwired/stimulus"

const DEBOUNCE_MS = 250

// Connects to data-controller="saved-search-picker"
//
// One instance per include/exclude box. Chips already chosen are server-
// rendered into the chips target on edit, so this controller must read the
// existing hidden inputs rather than assume it starts empty.
export default class extends Controller {
  static targets = ["query", "results", "chips", "limit"]
  // maxValue is opt-in: instances that don't set data-*-max-value get the
  // Number default of 0, which add() treats as "no cap" so the three
  // saved-search pickers (_criteria_fields.html.erb) are unaffected.
  static values = { url: String, name: String, max: Number }

  connect() {
    this.timer = null
    this.abortController = null
  }

  disconnect() {
    clearTimeout(this.timer)
    this.abortController?.abort()
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.run(), DEBOUNCE_MS)
  }

  // The picker sits inside the saved-search form, so Enter would submit it
  // mid-search. On a phone the keyboard's Search key IS Enter.
  suppressEnter(event) {
    if (event.key === "Enter") event.preventDefault()
  }

  async run() {
    this.abortController?.abort()

    const query = this.queryTarget.value.trim()
    if (query === "") {
      this.abortController = null
      this.clearResults()
      return
    }

    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("q", query)

    this.abortController = new AbortController()

    let rows = []
    try {
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        signal: this.abortController.signal
      })
      if (!response.ok) return
      rows = await response.json()
    } catch {
      return
    }

    // The abort above narrows the window but isn't instantaneous and doesn't
    // cover every interleaving (e.g. a response that lands just as add()
    // clears the query). Only apply results that still match what's typed.
    if (this.queryTarget.value.trim() !== query) return

    this.resultsTarget.replaceChildren(...rows.map((row) => this.resultButton(row)))
    this.resultsTarget.classList.toggle("hidden", rows.length === 0)
  }

  resultButton(row) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn btn-ghost btn-sm justify-start w-full"
    button.textContent = row.text
    button.dataset.value = row.value
    button.dataset.action = "saved-search-picker#add"
    return button
  }

  add(event) {
    const { value } = event.currentTarget.dataset
    const label = event.currentTarget.textContent

    if (this.selectedValues().includes(value)) return

    // maxValue === 0 means uncapped (the default for every instance that
    // doesn't opt in). A capped picker silently ignoring the click would be
    // its own bug, so the limit target -- if present -- gets an explicit
    // message instead of the chip being dropped without a word.
    if (this.maxValue > 0 && this.selectedValues().length >= this.maxValue) {
      this.showLimit()
      return
    }

    this.abortController?.abort()
    this.chipsTarget.appendChild(this.chip(value, label))
    this.queryTarget.value = ""
    this.clearResults()
  }

  remove(event) {
    event.currentTarget.closest("[data-chip]").remove()
    this.hideLimit()
  }

  showLimit() {
    if (!this.hasLimitTarget) return
    this.limitTarget.textContent = `You can exclude up to ${this.maxValue}. Remove one to add another.`
    this.limitTarget.classList.remove("hidden")
  }

  hideLimit() {
    if (this.hasLimitTarget) this.limitTarget.classList.add("hidden")
  }

  selectedValues() {
    return Array.from(this.chipsTarget.querySelectorAll("input[type=hidden]")).map((el) => el.value)
  }

  // Empty the results panel and hide it. Once the panel has a background and
  // shadow (to float over the page instead of pushing it down), leaving it
  // visible with zero children would show a small empty box floating over
  // the form. Called on query-cleared and on chip-added; the zero-results
  // case is handled inline in run() since it already has the fetched rows.
  clearResults() {
    this.resultsTarget.replaceChildren()
    this.resultsTarget.classList.add("hidden")
  }

  chip(value, label) {
    const wrapper = document.createElement("span")
    wrapper.className = "badge badge-outline gap-1"
    wrapper.dataset.chip = value

    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = this.nameValue
    hidden.value = value

    const text = document.createElement("span")
    text.textContent = label

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "btn btn-ghost btn-xs px-1"
    remove.textContent = "×"
    remove.setAttribute("aria-label", `Remove ${label}`)
    remove.dataset.action = "saved-search-picker#remove"

    wrapper.append(hidden, text, remove)
    return wrapper
  }
}

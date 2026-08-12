import { Controller } from "@hotwired/stimulus"

const DEBOUNCE_MS = 250

// Connects to data-controller="saved-search-picker"
//
// One instance per include/exclude box. Chips already chosen are server-
// rendered into the chips target on edit, so this controller must read the
// existing hidden inputs rather than assume it starts empty.
export default class extends Controller {
  static targets = ["query", "results", "chips"]
  static values = { url: String, name: String }

  connect() {
    this.timer = null
  }

  disconnect() {
    clearTimeout(this.timer)
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
    const query = this.queryTarget.value.trim()
    if (query === "") {
      this.resultsTarget.replaceChildren()
      return
    }

    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("q", query)

    let rows = []
    try {
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (!response.ok) return
      rows = await response.json()
    } catch {
      return
    }

    this.resultsTarget.replaceChildren(...rows.map((row) => this.resultButton(row)))
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

    this.chipsTarget.appendChild(this.chip(value, label))
    this.queryTarget.value = ""
    this.resultsTarget.replaceChildren()
  }

  remove(event) {
    event.currentTarget.closest("[data-chip]").remove()
  }

  selectedValues() {
    return Array.from(this.chipsTarget.querySelectorAll("input[type=hidden]")).map((el) => el.value)
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

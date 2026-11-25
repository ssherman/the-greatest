import { Controller } from "@hotwired/stimulus"
import autoComplete from "@tarekraafat/autocomplete.js"

const escapeHtml = (text) =>
  String(text).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char])

export default class extends Controller {
  static targets = ["input", "hiddenField"]
  static values = {
    url: String,
    minLength: { type: Number, default: 1 },
    debounce: { type: Number, default: 300 },
    displayKey: { type: String, default: "text" },
    valueKey: { type: String, default: "value" },
    // Optional last row of the dropdown (e.g. "Can't find it? Add a book").
    // Empty means no footer and nothing below changes.
    footerLabel: { type: String, default: "" },
    footerTestid: { type: String, default: "" }
  }

  connect() {
    this.abortController = null
    this.lastSelectedText = ''
    this.initAutoComplete()
    this.addInputListener()
  }

  disconnect() {
    if (this.autoComplete) {
      this.autoComplete = null
    }
    if (this.abortController) {
      this.abortController.abort()
    }
    this.removeInputListener()
  }

  initAutoComplete() {
    this.autoComplete = new autoComplete({
      selector: () => this.inputTarget,
      placeHolder: this.inputTarget.placeholder,
      threshold: this.minLengthValue,
      debounce: this.debounceValue,
      // A search still pending when the footer was chosen must not bring the
      // dropdown back over the page (typing or a real focus lifts the pause).
      trigger: (query) => !this.searchPaused && query.length >= this.minLengthValue,

      data: {
        src: async () => {
          if (this.abortController) {
            this.abortController.abort()
          }

          this.abortController = new AbortController()

          try {
            const query = this.inputTarget.value
            const separator = this.urlValue.includes('?') ? '&' : '?'
            const response = await fetch(
              `${this.urlValue}${separator}q=${encodeURIComponent(query)}`,
              {
                signal: this.abortController.signal,
                headers: {
                  'Accept': 'application/json',
                  'X-CSRF-Token': this.csrfToken
                }
              }
            )

            if (!response.ok) {
              throw new Error(`HTTP error! status: ${response.status}`)
            }

            return await response.json()
          } catch (error) {
            if (error.name === 'AbortError') {
              return []
            }
            console.error('Autocomplete fetch error:', error)
            return []
          }
        },
        keys: [this.displayKeyValue],
        // autocomplete.js writes each result's `match` into the page as HTML.
        // A title is text, so the match is escaped before the library sees it;
        // the selected value (`value`) stays the raw record, which is what
        // lands in the input and the events.
        filter: (matches) => matches.map((result) => ({ ...result, match: escapeHtml(result.match) })),
        cache: false
      },

      resultsList: {
        tag: "ul",
        class: "absolute dropdown-content p-2 shadow-lg bg-base-100 rounded-box w-full mt-1 max-h-80 overflow-y-auto z-[9999] left-0",
        maxResults: 25,
        noResults: true,
        position: "afterend",
        container: (element) => {
          element.style.position = "absolute"
          element.style.top = "100%"
          element.style.left = "0"
          element.style.right = "0"
          return element
        },
        element: (list, data) => {
          if (!data.results.length) {
            const message = document.createElement("div")
            message.className = "p-4 text-sm text-gray-500 text-center"
            message.textContent = `No results found for "${data.query}"`
            list.prepend(message)
          }
          this.appendFooter(list)
        }
      },

      resultItem: {
        tag: "li",
        class: "rounded-lg hover:bg-base-200 active:bg-base-300 cursor-pointer transition-colors px-4 py-2",
        highlight: false,
        selected: "bg-base-200"
      },

      events: {
        input: {
          selection: (event) => {
            // The footer is the one row with no result behind it.
            if (this.footerLabelValue && !event.detail.selection.value) {
              this.chooseFooter()
              return
            }
            const selection = event.detail.selection.value

            this.inputTarget.value = selection[this.displayKeyValue]
            this.lastSelectedText = selection[this.displayKeyValue]

            this.hiddenFieldTarget.value = selection[this.valueKeyValue]

            this.element.dispatchEvent(
              new CustomEvent('autocomplete:selected', {
                detail: { item: selection },
                bubbles: true
              })
            )
          },

          focus: () => {
            // Focus returned by code (a closed dialog) must not search again.
            if (this.inputTarget.hasAttribute("data-skip-focus-search")) return
            this.searchPaused = false
            if (this.inputTarget.value.length >= this.minLengthValue) {
              this.autoComplete.start()
            }
          }
        }
      }
    })
  }

  addInputListener() {
    this.handleInput = this.handleInput.bind(this)
    this.inputTarget.addEventListener('input', this.handleInput)
  }

  removeInputListener() {
    if (this.handleInput) {
      this.inputTarget.removeEventListener('input', this.handleInput)
    }
  }

  // The footer row: a real button inside a list item, so autocomplete.js treats
  // it like a result (arrow keys reach it, Enter or a click selects it) while
  // it is also a button to a pointer, a screen reader and a test. Built with
  // textContent only.
  buildFooter() {
    const item = document.createElement("li")
    item.id = `${this.inputTarget.id}_footer`
    item.setAttribute("role", "option")
    item.setAttribute("data-autocomplete-footer", "")
    item.className = "rounded-lg hover:bg-base-200 cursor-pointer transition-colors border-t border-base-300 mt-1"
    const button = document.createElement("button")
    button.type = "button"
    button.tabIndex = -1
    button.className = "w-full text-left px-4 py-2 font-semibold"
    button.textContent = this.footerLabelValue
    if (this.footerTestidValue) button.setAttribute("data-testid", this.footerTestidValue)
    item.appendChild(button)
    return item
  }

  // Called from autocomplete.js's own render, which has just rebuilt the list.
  appendFooter(list) {
    if (!this.footerLabelValue) return
    list.appendChild(this.buildFooter())
  }

  // Typing shows the footer at once, before the search for this query returns.
  // autocomplete.js only builds its list after the fetch, and a list that does
  // not exist yet has nothing to reach by keyboard.
  showFooterEarly() {
    const list = this.autoComplete?.list
    if (!list) return
    if (!list.querySelector("[data-autocomplete-footer]")) list.appendChild(this.buildFooter())
    // autocomplete.js navigation reads feedback.results; it is unset until the first search.
    if (!this.autoComplete.feedback) {
      this.autoComplete.feedback = { query: "", matches: [], results: [] }
      this.autoComplete.cursor = -1
    }
    if (!this.autoComplete.isOpen) this.autoComplete.open()
  }

  chooseFooter() {
    this.searchPaused = true
    this.element.dispatchEvent(
      new CustomEvent("autocomplete:footer", {
        detail: { query: this.inputTarget.value.trim() },
        bubbles: true
      })
    )
  }

  handleInput(event) {
    this.searchPaused = false
    const currentValue = event.target.value.trim()
    if (this.footerLabelValue && currentValue.length >= this.minLengthValue) this.showFooterEarly()

    // Clear hidden field if:
    // 1. Input is empty
    // 2. Input is below minimum length
    // 3. User is typing (not selecting from dropdown)
    if (!currentValue || currentValue.length < this.minLengthValue) {
      this.hiddenFieldTarget.value = ''
    } else {
      // If user is actively typing and we have a hidden field value,
      // check if the visible text matches what was selected
      // If not, clear the hidden field
      const hiddenValue = this.hiddenFieldTarget.value
      if (hiddenValue && this.inputTarget.value !== this.lastSelectedText) {
        this.hiddenFieldTarget.value = ''
      }
    }
  }

  get csrfToken() {
    return document.querySelector('[name="csrf-token"]')?.content || ''
  }
}

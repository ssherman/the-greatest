import { Controller } from "@hotwired/stimulus"
import autoComplete from "@tarekraafat/autocomplete.js"

export default class extends Controller {
  static targets = ["input", "hiddenField"]
  static values = {
    url: String,
    minLength: { type: Number, default: 2 },
    debounce: { type: Number, default: 300 },
    displayKey: { type: String, default: "text" },
    valueKey: { type: String, default: "value" }
  }

  connect() {
    this.abortController = null
    this.initAutoComplete()
  }

  disconnect() {
    if (this.autoComplete) {
      this.autoComplete = null
    }
    if (this.abortController) {
      this.abortController.abort()
    }
  }

  initAutoComplete() {
    this.autoComplete = new autoComplete({
      selector: () => this.inputTarget,
      placeHolder: this.inputTarget.placeholder,
      threshold: this.minLengthValue,
      debounce: this.debounceValue,

      data: {
        src: async () => {
          if (this.abortController) {
            this.abortController.abort()
          }

          this.abortController = new AbortController()

          try {
            const query = this.inputTarget.value
            const response = await fetch(
              `${this.urlValue}?q=${encodeURIComponent(query)}`,
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
        cache: false
      },

      resultsList: {
        tag: "ul",
        class: "absolute dropdown-content menu p-2 shadow-lg bg-base-100 rounded-box w-full mt-1 max-h-80 overflow-y-auto z-[60] left-0",
        maxResults: 5,
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
            const selection = event.detail.selection.value

            this.inputTarget.value = selection[this.displayKeyValue]

            this.hiddenFieldTarget.value = selection[this.valueKeyValue]

            this.element.dispatchEvent(
              new CustomEvent('autocomplete:selected', {
                detail: { item: selection },
                bubbles: true
              })
            )
          },

          focus: () => {
            if (this.inputTarget.value.length >= this.minLengthValue) {
              this.autoComplete.start()
            }
          }
        }
      }
    })
  }

  get csrfToken() {
    return document.querySelector('[name="csrf-token"]')?.content || ''
  }
}

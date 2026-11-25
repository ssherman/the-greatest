import { Controller } from "@hotwired/stimulus"

// The "Add a book that isn't on the site" dialog on a books list page.
//
// Opened by the add-item dropdown's footer (`autocomplete:footer`, carrying the
// search text) or by a strip row's Try another way (`book-submission:open`).
// Shows only the chosen method's inputs and disables the rest so they are not
// sent. The form posts through Turbo and the answers arrive as Turbo Streams:
// errors into #book-submission-errors, hits into #book-submission-hits, the
// strip into its frame. Reader text only ever goes into the page as `value` or
// `textContent`, never as markup.
const MAX_AUTHORS = 10
const AUTHOR_MAX_LENGTH = 255
// Where "Try another way" goes first, by the way that failed.
const RETRY_ORDER = ["title_authors", "isbn", "goodreads", "amazon"]
const SERVER_ERROR = "Could not reach the server. Check your connection and try again"

export default class extends Controller {
  static targets = ["radio", "group", "title", "authors", "addAuthor", "replaces", "errors", "hits", "form"]
  static values = { addItemSelector: String }

  connect() {
    this.opener = null
    this.hitsObserver = new MutationObserver(() => this.hitsChanged())
    this.hitsObserver.observe(this.hitsTarget, { childList: true })
    this.syncMethod()
  }

  disconnect() {
    this.hitsObserver?.disconnect()
    this.hitsObserver = null
  }

  openFromFooter(event) {
    const search = event.target?.querySelector?.('input[type="search"]')
    this.open({ opener: search, text: event.detail?.query || "" })
  }

  openForRetry(event) {
    const detail = event.detail || {}
    this.open({
      opener: detail.opener,
      replaces: detail.replaces,
      method: RETRY_ORDER.find((method) => method !== detail.inputMethod),
      title: detail.title,
      authors: detail.authors
    })
  }

  open({ opener = null, text = "", replaces = null, method = null, title = "", authors = [] } = {}) {
    if (this.element.open) return
    this.opener = opener || document.activeElement
    this.reset()

    if (text) this.titleTarget.value = text
    if (title) this.titleTarget.value = title
    if (authors.length) this.setAuthors(authors)
    if (method) this.chooseMethod(method)
    if (replaces) {
      this.replacesTarget.value = String(replaces)
      this.replacesTarget.disabled = false
    }

    this.element.showModal()
    this.focusFirstField()
  }

  close() {
    this.element.close()
  }

  // The dialog's native close event, whatever closed it (Cancel, Escape, the
  // backdrop, a finished submission).
  closed() {
    this.reset()
    const target = this.opener?.isConnected ? this.opener : this.addItemSearch()
    this.opener = null
    target?.focus?.()
  }

  methodChanged() {
    this.errorsTarget.textContent = ""
    this.syncMethod()
  }

  addAuthor() {
    const inputs = this.authorInputs()
    if (inputs.length >= MAX_AUTHORS) return
    const input = this.buildAuthorInput(inputs.length)
    this.authorsTarget.appendChild(input)
    this.addAuthorTarget.hidden = inputs.length + 1 >= MAX_AUTHORS
    input.focus()
  }

  // Hands the book to the existing add-item flow, the same event the dropdown
  // raises for a search result, and closes: that flow shows its own toast.
  addToList(event) {
    const { value, text } = event.currentTarget.dataset
    const addItem = document.querySelector(this.addItemSelectorValue)
    if (!value || !addItem) return
    addItem.dispatchEvent(
      new CustomEvent("autocomplete:selected", { detail: { item: { value, text } }, bubbles: true })
    )
    this.close()
  }

  // turbo:submit-end from either form in the dialog. A refusal (422, 429) puts
  // its message in the errors area by stream. An accepted request answers with
  // the strip frame, and then the dialog is done.
  async submitted(event) {
    const { success, fetchResponse, error } = event.detail
    if (error && !fetchResponse) {
      this.errorsTarget.textContent = SERVER_ERROR
      return
    }
    if (!success || !fetchResponse) return

    const body = await fetchResponse.responseText
    if (!body.includes('target="book_submissions"')) return
    this.formTarget.reset()
    this.close()
  }

  // A toast sits in the page, beneath an open modal dialog's top layer, so a
  // message meant as a toast (signed out, session expired, too fast, daily
  // limit) is also shown here while the dialog is open.
  mirrorToast(event) {
    if (!this.element.open) return
    const stream = event.target
    if (stream?.getAttribute?.("target") !== "toast-region") return
    const message = stream.templateElement?.content?.textContent?.trim()
    if (message) this.errorsTarget.textContent = message
  }

  // The hits replace the form; no hits brings it back.
  hitsChanged() {
    const hasHits = this.hitsTarget.childElementCount > 0
    this.formTarget.hidden = hasHits
    if (!hasHits) return
    this.errorsTarget.textContent = ""
    this.hitsTarget.querySelector('[tabindex="-1"]')?.focus()
  }

  reset() {
    this.errorsTarget.textContent = ""
    this.hitsTarget.textContent = ""
    this.formTarget.hidden = false
    this.replacesTarget.value = ""
    this.replacesTarget.disabled = true
    this.syncMethod()
  }

  syncMethod() {
    const selected = this.radioTargets.find((radio) => radio.checked)?.value
    this.groupTargets.forEach((group) => {
      const hidden = group.dataset.methodGroup !== selected
      group.hidden = hidden
      group.querySelectorAll("input").forEach((input) => { input.disabled = hidden })
    })
  }

  chooseMethod(method) {
    const radio = this.radioTargets.find((candidate) => candidate.value === method)
    if (!radio) return
    radio.checked = true
    this.syncMethod()
  }

  setAuthors(names) {
    const inputs = this.authorInputs()
    names.slice(0, MAX_AUTHORS).forEach((name, index) => {
      let input = inputs[index]
      if (!input) {
        input = this.buildAuthorInput(index)
        this.authorsTarget.appendChild(input)
      }
      input.value = name
    })
    this.addAuthorTarget.hidden = this.authorInputs().length >= MAX_AUTHORS
    this.syncMethod()
  }

  buildAuthorInput(index) {
    const input = document.createElement("input")
    input.type = "text"
    input.name = "book_submission[authors][]"
    input.id = `book_submission_authors_${index}`
    input.className = "input w-full"
    input.maxLength = AUTHOR_MAX_LENGTH
    input.autocomplete = "off"
    input.setAttribute("aria-label", `Author ${index + 1}`)
    return input
  }

  authorInputs() {
    return Array.from(this.authorsTarget.querySelectorAll("input"))
  }

  focusFirstField() {
    const group = this.groupTargets.find((candidate) => !candidate.hidden)
    group?.querySelector("input:not([disabled])")?.focus()
  }

  addItemSearch() {
    return document.querySelector(`${this.addItemSelectorValue} input[type="search"]`)
  }
}

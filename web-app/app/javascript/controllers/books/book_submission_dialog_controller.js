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
const DEFAULT_METHOD = "goodreads"
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
    this.accepted = false
    // The browser puts focus back on the search box when the dialog closes,
    // before our close handler runs; that focus must not search again.
    this.quietSearch = this.opener?.matches?.('input[type="search"]') ? this.opener : null
    this.quietSearch?.setAttribute("data-skip-focus-search", "")
    this.reset()

    // Title, authors and method come from this opening alone: what an earlier
    // row or search left in the fields never reaches this request.
    this.titleTarget.value = title || text
    this.setAuthors(authors.length ? authors : [""])
    this.chooseMethod(method || DEFAULT_METHOD)
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
    let target
    if (this.accepted && this.opener?.closest?.("#book_submissions")) {
      // The row this button was on is replaced by the answer; the strip's
      // wrapper is what survives.
      target = document.querySelector('[data-testid="book-submission-strip"]')
    } else if (this.opener?.isConnected) {
      target = this.opener
    } else {
      target = this.addItemSearch()
    }
    this.opener = null
    this.focusQuietly(target)
    this.quietSearch?.removeAttribute("data-skip-focus-search")
    this.quietSearch = null
  }

  // Focus the autocomplete's input without its focus handler searching again
  // and putting the dropdown back over the page.
  focusQuietly(element) {
    if (!element) return
    const search = element.matches?.('input[type="search"]')
    if (search) element.setAttribute("data-skip-focus-search", "")
    element.focus({ preventScroll: true })
    if (search) element.removeAttribute("data-skip-focus-search")
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
    if (!fetchResponse) {
      if (error) this.errorsTarget.textContent = SERVER_ERROR
      return
    }
    if (!success) {
      // A refusal we sent is a stream and has put its message in place. Anything
      // else (a 500 page, a proxy error) has said nothing to the reader.
      const type = fetchResponse.response?.headers?.get("content-type") || ""
      if (!type.includes("turbo-stream")) this.errorsTarget.textContent = SERVER_ERROR
      return
    }

    const body = await fetchResponse.responseText
    if (!body.includes('target="book_submissions"')) return
    this.accepted = true
    this.formTarget.reset()
    this.clearSearch()
    this.close()
  }

  // The request is made; the search text has done its job. Left in the box it
  // would reopen the dropdown over the strip row that confirms the add.
  clearSearch() {
    const search = this.addItemSearch()
    if (!search) return
    search.value = ""
    const hidden = search.closest('[data-controller~="autocomplete"]')?.querySelector('input[type="hidden"]')
    if (hidden) hidden.value = ""
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

  // Rebuilds the author inputs from these names alone: the first input stays,
  // the rest go, and as many are added as there are names (at most 10).
  setAuthors(names) {
    const [first, ...extra] = this.authorInputs()
    extra.forEach((input) => input.remove())
    const list = names.slice(0, MAX_AUTHORS)
    first.value = list[0] || ""
    list.slice(1).forEach((name, index) => {
      const input = this.buildAuthorInput(index + 1)
      input.value = name
      this.authorsTarget.appendChild(input)
    })
    this.addAuthorTarget.hidden = list.length >= MAX_AUTHORS
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

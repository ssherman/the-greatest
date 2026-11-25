import { Controller } from "@hotwired/stimulus"

// The strip of "Adding: ..." lines above a books list's items. This element
// wraps the Turbo Frame `book_submissions`; the frame itself is replaced by the
// write streams, so the controller lives outside it and watches it.
//
// The strip's state comes from one child of the frame, the element carrying
// data-poll-url, data-in-progress and data-reload-list. While data-in-progress
// is true the frame is reloaded from the poll url every 10 seconds, for at most
// 10 minutes from when polling began on this page, and only while the tab is
// visible. data-reload-list is consumed once, by removing it, so a Turbo cache
// restore or a second connect() cannot reload the list again.
const POLL_INTERVAL_MS = 10_000
const POLL_LIMIT_MS = 10 * 60 * 1000
const FRAME_ID = "book_submissions"
const STATE_SELECTOR = '[data-testid="book-submissions-state"]'

export default class extends Controller {
  // Set on the wrapper when polling starts and removed when it idles. It sits
  // in the DOM, so a Turbo cache restore of this page keeps the same clock.
  static values = { startedAt: Number }

  connect() {
    this.timer = null
    this.stopped = false
    this.onVisibility = () => { if (!document.hidden) this.sync() }
    this.onFetchResponse = (event) => this.fetchResponded(event)
    this.onFetchError = (event) => this.fetchFailed(event)
    // A write's answer is fresh state, so a stopped poller may start again.
    this.onStream = () => { this.stopped = false }
    document.addEventListener("visibilitychange", this.onVisibility)
    document.addEventListener("turbo:before-stream-render", this.onStream)
    this.element.addEventListener("turbo:before-fetch-response", this.onFetchResponse)
    this.element.addEventListener("turbo:fetch-request-error", this.onFetchError)
    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.element, { childList: true, subtree: true })
    this.sync()
  }

  disconnect() {
    this.clearTimer()
    this.observer?.disconnect()
    this.observer = null
    document.removeEventListener("visibilitychange", this.onVisibility)
    document.removeEventListener("turbo:before-stream-render", this.onStream)
    this.element.removeEventListener("turbo:before-fetch-response", this.onFetchResponse)
    this.element.removeEventListener("turbo:fetch-request-error", this.onFetchError)
  }

  // "Try another way" on a row: the dialog opens with that row replaced. Reader
  // text travels in data attributes and is only ever read back as strings.
  tryAnother(event) {
    const button = event.currentTarget
    let authors = []
    try {
      const parsed = JSON.parse(button.dataset.authors || "[]")
      if (Array.isArray(parsed)) authors = parsed.filter((name) => typeof name === "string")
    } catch (_error) {
      authors = []
    }
    window.dispatchEvent(new CustomEvent("book-submission:open", {
      detail: {
        opener: button,
        replaces: button.dataset.replaces,
        inputMethod: button.dataset.inputMethod,
        title: button.dataset.title || "",
        authors
      }
    }))
  }

  // Reads the strip as it is now: consumes a list reload, then decides whether
  // to keep polling. Called on connect, on every change inside the wrapper and
  // when the tab becomes visible again.
  sync() {
    const state = this.element.querySelector(STATE_SELECTOR)
    if (!state) {
      this.idle()
      return
    }

    if (state.hasAttribute("data-reload-list")) {
      state.removeAttribute("data-reload-list")
      this.reloadList()
    }

    if (state.dataset.inProgress === "true" && state.dataset.pollUrl && !this.stopped) {
      this.schedule()
    } else {
      this.idle()
    }
  }

  schedule() {
    if (!this.startedAtValue) this.startedAtValue = Date.now()
    if (Date.now() - this.startedAtValue >= POLL_LIMIT_MS) {
      this.clearTimer()
      return
    }
    if (this.timer || document.hidden) return
    this.timer = setTimeout(() => {
      this.timer = null
      this.poll()
    }, POLL_INTERVAL_MS)
  }

  idle() {
    this.clearTimer()
    if (this.startedAtValue) this.startedAtValue = 0
  }

  clearTimer() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  }

  poll() {
    const state = this.element.querySelector(STATE_SELECTOR)
    const frame = document.getElementById(FRAME_ID)
    if (!state?.dataset.pollUrl || !frame) return
    if (Date.now() - this.startedAtValue >= POLL_LIMIT_MS || document.hidden) return

    const url = new URL(state.dataset.pollUrl, window.location.href).href
    const current = frame.getAttribute("src")
    if (current && new URL(current, window.location.href).href === url && typeof frame.reload === "function") {
      frame.reload()
    } else {
      frame.src = url
    }
    // The answer replaces the frame's children, which calls sync() again.
  }

  // Any answer that is not OK ends polling: signed out, a list that is gone,
  // a server error. The server answers those with an empty frame.
  fetchResponded(event) {
    if (!this.isStripFrame(event.target) || event.detail?.fetchResponse?.succeeded) return
    this.stopped = true
    this.clearTimer()
  }

  fetchFailed(event) {
    if (!this.isStripFrame(event.target)) return
    this.stopped = true
    this.clearTimer()
  }

  // Cancel and dismiss forms inside the frame raise the same events; only the
  // frame's own loads (the polls) say anything about whether polling works.
  isStripFrame(target) {
    return target instanceof Element && target.id === FRAME_ID && target.tagName === "TURBO-FRAME"
  }

  // The same reload the add-item dropdown does after an add, then the shared
  // user-list state is refreshed so the add-to-list widgets are not stale.
  reloadList() {
    const frame = document.getElementById("list_items")
    if (!frame || typeof frame.reload !== "function") {
      window.location.reload()
      return
    }
    if (frame.src) {
      frame.reload()
    } else {
      frame.src = window.location.href
    }
    const stateController = window.Stimulus?.getControllerForElementAndIdentifier?.(document.body, "user-list-state")
    stateController?.refresh?.({ conditional: false })
  }
}

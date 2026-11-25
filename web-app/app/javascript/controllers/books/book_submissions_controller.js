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
    // A write's answer that replaces the strip is fresh state: a stopped poller
    // may start again and the 10 minutes begin anew. Other streams (toasts, the
    // dialog's error line) say nothing about the strip.
    this.onStream = (event) => {
      if (event.target?.getAttribute?.("target") !== FRAME_ID) return
      this.stopped = false
      this.startedAtValue = 0
    }
    this.onFrameMissing = (event) => this.frameMissing(event)
    this.onBeforeFrameRender = (event) => this.beforeFrameRender(event)
    document.addEventListener("visibilitychange", this.onVisibility)
    document.addEventListener("turbo:before-stream-render", this.onStream)
    this.element.addEventListener("turbo:before-fetch-response", this.onFetchResponse)
    this.element.addEventListener("turbo:fetch-request-error", this.onFetchError)
    this.element.addEventListener("turbo:frame-missing", this.onFrameMissing)
    this.element.addEventListener("turbo:before-frame-render", this.onBeforeFrameRender)
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
    this.element.removeEventListener("turbo:frame-missing", this.onFrameMissing)
    this.element.removeEventListener("turbo:before-frame-render", this.onBeforeFrameRender)
  }

  // An answer that is not our frame (a 502 page, a proxy error) would replace
  // the strip with "Content missing" or navigate the page. Keep the rows; the
  // poll that got it has already stopped polling (fetchResponded).
  frameMissing(event) {
    if (!this.isStripFrame(event.target)) return
    event.preventDefault()
  }

  // A poll that answers with the rows it already shows swaps nothing, so focus
  // stays put and the live region has nothing to announce; only the state
  // attributes are read. When the rows did change, the swap happens and the
  // focused button (found again by its row and label) gets its focus back.
  beforeFrameRender(event) {
    const frame = event.target
    if (!this.isStripFrame(frame) || typeof event.detail?.render !== "function") return

    const original = event.detail.render
    event.detail.render = (current, next) => {
      if (this.rowsOf(current) === this.rowsOf(next) && current.querySelector(STATE_SELECTOR)) {
        this.copyState(current, next)
        this.sync()
        return
      }
      const focused = this.focusedControl(current)
      original(current, next)
      this.restoreFocus(current, focused)
    }
  }

  // The rows as text, without what changes on every response: button_to puts a
  // masked authenticity token in every form. A kept row keeps its older token,
  // which stays valid for the session.
  rowsOf(root) {
    return Array.from(root.querySelectorAll('[data-testid="book-submission-row"]'))
      .map((row) => {
        const copy = row.cloneNode(true)
        copy.querySelectorAll('input[name="authenticity_token"]').forEach((input) => input.remove())
        return copy.outerHTML
      })
      .join("")
  }

  copyState(current, next) {
    const from = next.querySelector(STATE_SELECTOR)
    const to = current.querySelector(STATE_SELECTOR)
    if (!to) return
    for (const name of ["data-poll-url", "data-in-progress", "data-reload-list"]) {
      const value = from?.getAttribute(name)
      if (value === null || value === undefined) to.removeAttribute(name)
      else to.setAttribute(name, value)
    }
  }

  focusedControl(current) {
    const active = document.activeElement
    if (!active || active === document.body || !current.contains(active)) return null
    const row = active.closest('[data-testid="book-submission-row"]')
    return { rowId: row?.id, label: active.textContent.trim() }
  }

  restoreFocus(current, focused) {
    if (!focused) return
    const row = focused.rowId ? current.querySelector(`#${CSS.escape(focused.rowId)}`) : null
    const control = row && Array.from(row.querySelectorAll("button")).find((button) => button.textContent.trim() === focused.label)
    if (control) control.focus()
    else this.element.focus({ preventScroll: true })
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

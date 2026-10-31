import { Controller } from "@hotwired/stimulus"

// Bump when the persisted state shape changes (e.g. memberships went from
// [list_id] to [{list_id, item_id}] tuples; 3 added etag, checkedAt, seenMark
// and membership). On load, caches stamped with a different schema are
// discarded so users don't render against stale shapes.
const STATE_SCHEMA = 3

// How long a cached entry is trusted before a page load re-checks it. Changes
// made on this device are applied locally or flagged by tg_state_mark, so this
// only bounds how late a change made elsewhere (another device, a membership
// expiring) shows up.
const RECHECK_AFTER_MS = 60 * 60 * 1000

// After a re-check fails (network error, 429, 5xx, a Cloudflare challenge),
// how long page loads leave a struggling origin alone. Without it every
// signed-in page view would retry. Clicks that need the state still ask.
const RETRY_AFTER_FAILURE_MS = 5 * 60 * 1000

// Shared by every instance in this document. Turbo replaces <body> on each
// visit, so each visit connects a fresh instance, and a visit that first shows
// a cached snapshot connects two in quick succession. Holding the in-flight
// request here is what stops that pair from making two requests; the response
// is applied to whichever instance is live when it lands.
let inflight = null // { conditional, promise }
let liveInstance = null
// Bumped whenever the entry is discarded for a sign-out, a sign-in or a 401. A
// response to a request started before the bump belongs to whoever was signed
// in then, so it may not write storage or reach the page. tg_uid alone cannot
// tell: an in-page sign-out dispatches auth:signout before /auth/sign_out has
// answered and deleted the cookie.
let clearEpoch = 0

// Reads the plain tg_state_mark cookie. Rails changes its value on every write
// that alters this visitor's lists or membership, so a value different from the
// one the entry was checked against means the entry is out of date.
function currentMark() {
  const m = document.cookie.match(/(?:^|;\s*)tg_state_mark=([^;]+)/)
  return m ? decodeURIComponent(m[1]) : null
}

// Singleton controller. Holds per-user list/membership state in localStorage
// and broadcasts events on window so per-card widgets, the singleton modal and
// the Members link can render from it.
//
// A page load makes at most one Rails request, and usually none: the entry is
// re-checked (conditionally, so usually a 304) only when it is missing, older
// than RECHECK_AFTER_MS, or tg_state_mark has moved, and never on a page that
// already costs a request by loading (pageCostsRequest). Requests caused by a
// click (opening the list modal, a write, Download CSV) are outside that budget.
//
// Storage shape: { version, domain, user_id, lists, memberships, membership,
//                  etag, checkedAt, seenMark, _schema }
// Event names emitted on window:
//   - "user-list-state:loaded"  (cache hit, may be stale)
//   - "user-list-state:updated" (network response or local write superseded cache)
//   - "user-list-state:cleared" (sign-out detected)
export default class extends Controller {
  static values = {
    url: { type: String, default: "/user_list_state" }
  }

  connect() {
    liveInstance = this
    this.domain = document.body.dataset.domain || "books"
    this.storageKey = `tg:user_list_state:${this.domain}`
    this.signedIn = false
    this.cache = null
    // CSRF token is held in memory only — never persisted to localStorage.
    // The cached HTML's <meta name="csrf-token"> is unreliable on CDN-cached
    // pages, so mutations must use the token from the latest /user_list_state.
    // A 304 carries none, so ensureCsrf() asks for the full payload.
    this.csrf = null
    // tg_state_mark as beginWrite() saw it just before the write in flight
    // was sent; undefined when no write has announced itself (see
    // applyMutation for why a write needs it).
    this._preWriteMark = undefined
    // tg_uid as beginWrite() saw it: the user the write in flight belongs to.
    // Another tab can sign out and in as someone else before the response
    // lands, and this tab's clearEpoch never hears of it.
    this._writeUid = undefined

    this._onAuthSuccess = this._onAuthSuccess.bind(this)
    this._onAuthSignout = this._onAuthSignout.bind(this)
    window.addEventListener("auth:success", this._onAuthSuccess)
    window.addEventListener("auth:signout", this._onAuthSignout)

    // Hydration is gated on the tg_uid cookie (set by AuthController on sign-in,
    // backfilled by /user_list_state). This prevents a previous user's cache
    // from rendering on a shared browser after sign-out / session expiry.
    if (this.cookieUid()) {
      // The nav links follow the same signal as the navbar button (tg_uid), so
      // a failed or throttled fetch never leaves "Logout" without its My link.
      // Only a 401 or a sign-out hides them again.
      this._updateMyListsNav(true)
      this._hydrateFromStorage()
      // Turbo's restore of a snapshot re-runs connect() too; the same gate
      // keeps Back from costing a request while the entry is fresh.
      if (this.isStale() && !this.pageCostsRequest()) this.refresh({ conditional: true })
    } else {
      // No signed-in marker — discard any stale cache and stay anonymous.
      // We deliberately skip the network fetch: the endpoint requires auth
      // and would just return 401.
      this._clearStorage()
      this._updateMyListsNav(false)
    }
  }

  // Reveals/hides the signed-in-only nav links. They ship hidden in cached
  // HTML and are revealed client-side once sign-in is detected — same approach
  // as the Login/Logout toggle — so the navbar stays CDN-cacheable.
  // querySelectorAll covers both the mobile and desktop menu copies. Books
  // groups its personal links under one hook; Music and Games retain their
  // existing My Lists hook.
  _updateMyListsNav(visible) {
    const selector = this.domain === "books" ? "#navbar_my_books" : "#navbar_my_lists"
    document.querySelectorAll(selector).forEach((el) => {
      el.classList.toggle("hidden", !visible)
    })
  }

  // Reads the non-HttpOnly tg_uid cookie set by AuthController on sign-in.
  // Returns the user id as a string, or null if the cookie is absent.
  cookieUid() {
    const m = document.cookie.match(/(?:^|;\s*)tg_uid=([^;]+)/)
    return m ? decodeURIComponent(m[1]) : null
  }

  disconnect() {
    if (liveInstance === this) liveInstance = null
    window.removeEventListener("auth:success", this._onAuthSuccess)
    window.removeEventListener("auth:signout", this._onAuthSignout)
  }

  // Returns the current in-memory state (or null if none).
  state() {
    return this.cache
  }

  isSignedIn() {
    return this.signedIn
  }

  // Returns the in-memory CSRF token (only available after a full fetch).
  csrfToken() {
    return this.csrf
  }

  // True when this page already cost a Rails request by loading: an uncached
  // Rails page (the layout's tg-page-request meta) or a page whose own markup
  // makes a state request on load (book show's review widget, a public reading
  // goal). The re-check waits for the next page that costs nothing. Both
  // markers are identical for every visitor, so cached HTML stays shareable.
  pageCostsRequest() {
    return !!document.querySelector('meta[name="tg-page-request"], [data-tg-page-request]')
  }

  // True when the entry is missing, was last checked more than an hour ago (or
  // in the future: a clock that moved backwards must not freeze it), or a write
  // since then moved tg_state_mark.
  isStale() {
    const entry = this.cache
    if (!entry) return true
    // Backing off after a failed re-check outranks both other reasons. The
    // upper bound keeps a clock moved backwards from stretching the wait.
    const wait = (entry.retryAfter || 0) - Date.now()
    if (wait > 0 && wait <= RETRY_AFTER_FAILURE_MS) return false
    const age = Date.now() - entry.checkedAt
    if (!(age >= 0 && age <= RECHECK_AFTER_MS)) return true
    return currentMark() !== (entry.seenMark ?? null)
  }

  // For a widget or the modal on first interaction: fetches the state only
  // when this page has none (e.g. a book page right after sign-in, which could
  // not spend its request on it). Resolves to the refresh status, or "cached".
  async ensureState() {
    if (this.cache) return "cached"
    if (!this.cookieUid()) return "unauthenticated"
    return this.refresh({ conditional: false })
  }

  // Ensures a fresh CSRF token is available before a mutation, fetching once
  // if none. Unconditional, because a 304 carries no token. Concurrent calls
  // share a single in-flight request. Resolves to a token, or null only when
  // the fetch definitely failed (network, 401, a response dropped as another
  // user's): refresh() never settles for a 304 here (_refreshFull).
  async ensureCsrf() {
    if (this.csrf) return this.csrf
    await this.refresh({ conditional: false })
    return this.csrf
  }

  // Asks /user_list_state for this user's state. Conditional sends the entry's
  // ETag, so an unchanged state costs a 304 with no body. Resolves to "updated"
  // (200), "unchanged" (304), "unauthenticated" (401) or "failed"; the result
  // is applied to the live instance before it resolves. Concurrent callers in
  // this document share one request, except that a caller needing the full
  // payload does not settle for a 304.
  refresh({ conditional = false } = {}) {
    if (inflight && (conditional || !inflight.conditional)) return inflight.promise
    if (inflight) return this._refreshFull()
    return this._start(conditional)
  }

  // An unconditional caller behind a conditional request: a 200 from it is as
  // good as our own, but a 304 has no token, so wait it out and fetch in full.
  // Loops because by then another conditional request may have started, and
  // joining that one could end in a 304 too.
  async _refreshFull() {
    while (inflight?.conditional) {
      const status = await inflight.promise
      if (status !== "unchanged") return status
    }
    return inflight ? inflight.promise : this._start(false)
  }

  _start(conditional) {
    const current = { conditional, promise: null }
    current.promise = this._fetchState(conditional)
      .then((outcome) => {
        liveInstance?._adopt(outcome)
        return outcome.status
      })
      .finally(() => {
        if (inflight === current) inflight = null
      })
    inflight = current
    return current.promise
  }

  // Performs the request and updates storage and cookies; in-memory state and
  // events are the live instance's business (_adopt).
  async _fetchState(conditional) {
    const epoch = clearEpoch
    const uid = this.cookieUid()
    const entry = conditional ? this._readEntry(uid) : null
    const snapshot = entry ? JSON.stringify(entry) : null
    // Read before the request, not after: a write landing while it is in
    // flight moves the mark, and recording that newer value against this older
    // response would hide the write.
    const mark = currentMark()
    const headers = { Accept: "application/json" }
    if (entry?.etag) headers["If-None-Match"] = entry.etag

    let response
    try {
      response = await fetch(this.urlValue, { headers, credentials: "same-origin" })
    } catch (err) {
      console.warn("user-list-state: network error", err)
      this._backOff(epoch)
      return { status: "failed" }
    }

    // Signed out, signed in or 401'd while this was in flight: whatever it
    // says belongs to the previous user. (A 401 still needs no handling: the
    // clearing it would do has already happened.)
    if (epoch !== clearEpoch) return { status: "failed" }

    if (response.status === 304) {
      // Re-read rather than restore the snapshot: a local write applied while
      // this was in flight is newer than the snapshot and must survive. The
      // entry must still be there and still be this user's.
      const current = this._readEntry(this.cookieUid())
      if (!entry || !current || String(current.user_id) !== String(entry.user_id)) return { status: "failed" }
      // The server only vouched for the snapshot. If a local write has since
      // changed the entry, seenMark stays as that write left it.
      const unchangedLocally = JSON.stringify(current) === snapshot
      const { retryAfter: _retryAfter, ...rest } = current
      const next = { ...rest, checkedAt: Date.now(), seenMark: unchangedLocally ? mark : current.seenMark }
      this._writeStorage(next)
      return { status: "unchanged", entry: next }
    }

    if (response.status === 401) {
      clearEpoch++
      this._clearStorage()
      this._clearCookieUid()
      return { status: "unauthenticated" }
    }

    if (!response.ok) {
      console.warn("user-list-state: unexpected status", response.status)
      this._backOff(epoch)
      return { status: "failed" }
    }

    let data
    try {
      data = await response.json()
    } catch (err) {
      console.warn("user-list-state: unreadable response", err)
      this._backOff(epoch)
      return { status: "failed" }
    }

    // Rails re-stamps tg_uid from the session on this response, so a mismatch
    // here means a sign-out (or a different sign-in) landed while the request
    // was in flight. Keep that user's data out of storage and off the page.
    // The epoch is checked again because reading the body yielded.
    if (epoch !== clearEpoch || String(data.user_id) !== this.cookieUid()) return { status: "failed" }

    // Strip csrf_token from the persisted shape so it never lands in localStorage.
    const { csrf_token: csrf, ...persistable } = data
    const next = {
      ...persistable,
      etag: response.headers.get("ETag"),
      checkedAt: Date.now(),
      seenMark: mark
    }
    this._writeStorage(next)
    return { status: "updated", entry: next, csrf: csrf || null }
  }

  // Stamps the stored entry so page loads skip the re-check for
  // RETRY_AFTER_FAILURE_MS. Only for a failure to get an answer: a 401 clears
  // instead, and a response dropped as another user's (epoch, user_id) says
  // nothing about the origin. Without an entry there is nothing to stamp.
  _backOff(epoch) {
    if (epoch !== clearEpoch) return
    const uid = this.cookieUid()
    const current = this._readEntry(uid)
    if (!current) return
    const next = { ...current, retryAfter: Date.now() + RETRY_AFTER_FAILURE_MS }
    this._writeStorage(next)
    if (liveInstance?.cache && String(liveInstance.cache.user_id) === uid) liveInstance.cache = next
  }

  _adopt(outcome) {
    // Belt and braces for the checks in _fetchState: with no tg_uid there is
    // no one to show a user's state to.
    if ((outcome.status === "updated" || outcome.status === "unchanged") && !this.cookieUid()) return
    switch (outcome.status) {
    case "updated":
      // The network response is authoritative — always replace the cache.
      this.cache = outcome.entry
      this.csrf = outcome.csrf
      this.signedIn = true
      this._updateMyListsNav(true)
      this._dispatch("user-list-state:updated", { state: this.cache })
      break
    case "unchanged": {
      // Nothing new to render: only "last checked" moved. An instance that had
      // no entry in memory still announces the one it now holds.
      const hadEntry = !!this.cache
      this.cache = outcome.entry
      this.signedIn = true
      if (!hadEntry) this._dispatch("user-list-state:loaded", { state: this.cache })
      break
    }
    case "unauthenticated":
      this.signedIn = false
      this.cache = null
      this.csrf = null
      this._updateMyListsNav(false)
      this._dispatch("user-list-state:cleared")
      break
    }
  }

  // Called by every write path just before it sends the write (after any
  // ensureCsrf). Records the mark the write starts from, and brings this tab's
  // copy up to date with the stored entry, which another tab may have changed
  // since this page loaded, so the write's caller computes from that.
  beginWrite() {
    this._preWriteMark = currentMark()
    this._writeUid = this.cookieUid()
    const stored = this._readEntry(this.cookieUid())
    if (stored && JSON.stringify(stored) !== JSON.stringify(this.cache)) {
      this.cache = stored
      this._dispatch("user-list-state:updated", { state: stored })
    }
  }

  // Optimistically apply a mutation result and rebroadcast. Called by the modal
  // after a successful add/remove/create. `memberships` is the new full array
  // of {list_id, item_id} tuples for this (listableType, listableId).
  applyMutation({ listableType, listableId, memberships, addedList, removedListId }) {
    // Rebase on the stored entry, not this tab's copy: another tab may have
    // written to it since, and writing this tab's copy back would undo that.
    // In-memory only when storage is unusable (quota) but the copy is this
    // user's.
    const uid = this.cookieUid()
    const writeUid = this._writeUid
    this._writeUid = undefined
    // The write belongs to whoever was signed in when it started. If another
    // tab has since signed in as someone else, this response describes that
    // earlier user's lists and must not be merged into the new user's entry.
    // Dropping it costs nothing: the earlier user's server state already has
    // the write.
    if (writeUid !== undefined && writeUid !== uid) {
      this._preWriteMark = undefined
      return
    }
    const base = this._readEntry(uid) ??
      (this.cache && uid != null && String(this.cache.user_id) === uid ? this.cache : null)
    if (!base) return
    const next = JSON.parse(JSON.stringify(base))

    if (addedList) {
      const exists = next.lists.find((l) => l.id === addedList.id)
      if (!exists) next.lists.push(addedList)
    }

    if (removedListId) {
      next.lists = next.lists.filter((l) => l.id !== removedListId)
    }

    if (listableType && listableId) {
      const key = String(listableId)
      next.memberships[listableType] ||= {}
      next.memberships[listableType][key] = memberships
      if (!memberships.length) delete next.memberships[listableType][key]
    }

    next.version = Math.floor(Date.now() / 1000)
    // The write's response just moved tg_state_mark, and the entry now holds
    // that write. It may be marked seen only if the entry already held every
    // change before it: its seenMark equals the mark this write started from.
    // Otherwise some change it does not hold (another tab's widget write
    // stored without being applied here, a Rails page like /membership/thanks)
    // moved the mark first, and marking it seen would hide that change for up
    // to an hour. Left unseen, the next page that can re-check will.
    // The recorded mark is spent here, so of two overlapping writes only the
    // first can mark anything seen: one extra re-check, never a hidden change.
    const pre = this._preWriteMark
    this._preWriteMark = undefined
    if (pre !== undefined && (base.seenMark ?? null) === pre) next.seenMark = currentMark()
    this.cache = next
    this._writeStorage(next)
    this._dispatch("user-list-state:updated", { state: next })
  }

  // The stored entry, if it has the current shape and belongs to `uid`.
  // Anything else is removed so it can never render.
  _readEntry(uid) {
    try {
      const raw = window.localStorage.getItem(this.storageKey)
      if (!raw) return null
      const parsed = JSON.parse(raw)
      if (parsed?._schema !== STATE_SCHEMA) {
        // Stored under an older shape — discard so we don't render bad UI.
        window.localStorage.removeItem(this.storageKey)
        return null
      }
      // Bind cache to the current signed-in user. If cookie uid doesn't match
      // the cached user_id, this is a different user on a shared browser —
      // discard the previous user's data instead of rendering it. An entry
      // with no user_id is treated the same way.
      if (uid == null || String(parsed.user_id) !== uid) {
        window.localStorage.removeItem(this.storageKey)
        return null
      }
      return parsed
    } catch (err) {
      console.warn("user-list-state: storage read failed", err)
      return null
    }
  }

  _hydrateFromStorage() {
    const entry = this._readEntry(this.cookieUid())
    if (!entry) return
    this.cache = entry
    this.signedIn = true
    this._updateMyListsNav(true)
    this._dispatch("user-list-state:loaded", { state: this.cache })
  }

  _writeStorage(state) {
    try {
      window.localStorage.setItem(this.storageKey, JSON.stringify({...state, _schema: STATE_SCHEMA}))
    } catch (err) {
      // QuotaExceededError or similar — fall back to in-memory only.
      console.warn("user-list-state: storage write failed (quota?)", err)
    }
  }

  _clearStorage() {
    try { window.localStorage.removeItem(this.storageKey) } catch (_) { /* ignore */ }
  }

  // Clears the non-HttpOnly tg_uid cookie. Used when the server reports the
  // session is no longer valid (401) so a stale cookie doesn't keep gating
  // future hydration as if signed in.
  _clearCookieUid() {
    document.cookie = "tg_uid=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/; SameSite=Lax"
  }

  _dispatch(name, detail = {}) {
    window.dispatchEvent(new CustomEvent(name, { detail }))
  }

  // Every sign-in modal reloads the page on success (reload_after_auth), so
  // there is nothing to fetch here: dropping the entry is enough for the next
  // page to fetch the new user's state, and keeps any earlier user's out.
  _onAuthSuccess() {
    clearEpoch++
    this._clearStorage()
    this.cache = null
    this.csrf = null
    this._preWriteMark = undefined
    this._writeUid = undefined
    this._updateMyListsNav(true)
  }

  _onAuthSignout() {
    clearEpoch++
    this._clearStorage()
    this.signedIn = false
    this.cache = null
    this.csrf = null
    this._preWriteMark = undefined
    this._writeUid = undefined
    this._updateMyListsNav(false)
    this._dispatch("user-list-state:cleared")
  }
}

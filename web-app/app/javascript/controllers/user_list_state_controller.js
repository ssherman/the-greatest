import { Controller } from "@hotwired/stimulus"

// Bump when the persisted state shape changes (e.g. memberships went from
// [list_id] to [{list_id, item_id}] tuples). On load, caches stamped with a
// different schema are discarded so users don't render against stale shapes.
const STATE_SCHEMA = 2

// Singleton controller. Hydrates per-user list/membership state from
// localStorage, then refreshes from /user_list_state. Broadcasts events on
// window so per-card widgets and the singleton modal can re-render.
//
// Storage shape: { version, domain, lists, memberships }
// Event names emitted on window:
//   - "user-list-state:loaded"  (cache hit, may be stale)
//   - "user-list-state:updated" (network response superseded cache)
//   - "user-list-state:cleared" (sign-out detected)
export default class extends Controller {
  static values = {
    url: { type: String, default: "/user_list_state" }
  }

  connect() {
    this.domain = document.body.dataset.domain || "books"
    this.storageKey = `tg:user_list_state:${this.domain}`
    this.signedIn = false
    this.cache = null
    // CSRF token is held in memory only — never persisted to localStorage.
    // The cached HTML's <meta name="csrf-token"> is unreliable on CDN-cached
    // pages, so mutations must use the token from the latest /user_list_state.
    this.csrf = null
    this._inflightRefresh = null

    this._onAuthSuccess = this._onAuthSuccess.bind(this)
    this._onAuthSignout = this._onAuthSignout.bind(this)
    window.addEventListener("auth:success", this._onAuthSuccess)
    window.addEventListener("auth:signout", this._onAuthSignout)

    // Hydration is gated on the tg_uid cookie (set by AuthController on sign-in,
    // backfilled by /user_list_state). This prevents a previous user's cache
    // from rendering on a shared browser after sign-out / session expiry.
    if (this.cookieUid()) {
      this._hydrateFromStorage()
      this.refresh()
    } else {
      // No signed-in marker — discard any stale cache and stay anonymous.
      // We deliberately skip the network fetch: the endpoint requires auth
      // and would just return 401.
      this._clearStorage()
    }
  }

  // Reads the non-HttpOnly tg_uid cookie set by AuthController on sign-in.
  // Returns the user id as a string, or null if the cookie is absent.
  cookieUid() {
    const m = document.cookie.match(/(?:^|;\s*)tg_uid=([^;]+)/)
    return m ? decodeURIComponent(m[1]) : null
  }

  disconnect() {
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

  // Returns the in-memory CSRF token (only available after a successful fetch).
  csrfToken() {
    return this.csrf
  }

  // Ensures a fresh CSRF token is available before a mutation, fetching once
  // if none. Coalesces concurrent calls onto a single in-flight request.
  async ensureCsrf() {
    if (this.csrf) return this.csrf
    await this.refresh()
    return this.csrf
  }

  // Re-fetch /user_list_state. If the response version is newer than the cached
  // version, persist + dispatch updated. On 401, treat as signed out.
  // Concurrent callers share a single in-flight promise.
  refresh() {
    if (this._inflightRefresh) return this._inflightRefresh
    this._inflightRefresh = this._doRefresh().finally(() => {
      this._inflightRefresh = null
    })
    return this._inflightRefresh
  }

  async _doRefresh() {
    let response
    try {
      response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
    } catch (err) {
      console.warn("user-list-state: network error", err)
      return
    }

    if (response.status === 401) {
      this._clearStorage()
      this._clearCookieUid()
      this.signedIn = false
      this.cache = null
      this.csrf = null
      this._dispatch("user-list-state:cleared")
      return
    }

    if (!response.ok) {
      console.warn("user-list-state: unexpected status", response.status)
      return
    }

    const data = await response.json()
    this.signedIn = true
    this.csrf = data.csrf_token || null
    // Strip csrf_token from the persisted shape so it never lands in localStorage.
    const { csrf_token: _csrf, ...persistable } = data

    // The network response is authoritative — always replace the cache.
    // (We previously skipped the write when versions matched, but local
    // optimistic mutations stamp the cache with Date.now(), which can be
    // ahead of server `user.updated_at.to_i`, suppressing legitimate updates.)
    this.cache = persistable
    this._writeStorage(persistable)
    this._dispatch("user-list-state:updated", { state: persistable })
  }

  // Optimistically apply a mutation result and rebroadcast. Called by the modal
  // after a successful add/remove/create. `memberships` is the new full array
  // of {list_id, item_id} tuples for this (listableType, listableId).
  applyMutation({ listableType, listableId, memberships, addedList, removedListId }) {
    if (!this.cache) return
    const next = JSON.parse(JSON.stringify(this.cache))

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
    this.cache = next
    this._writeStorage(next)
    this._dispatch("user-list-state:updated", { state: next })
  }

  _hydrateFromStorage() {
    try {
      const raw = window.localStorage.getItem(this.storageKey)
      if (!raw) return
      const parsed = JSON.parse(raw)
      if (parsed?._schema !== STATE_SCHEMA) {
        // Stored under an older shape — discard so we don't render bad UI.
        window.localStorage.removeItem(this.storageKey)
        return
      }
      // Bind cache to the current signed-in user. If cookie uid doesn't match
      // the cached user_id, this is a different user on a shared browser —
      // discard the previous user's data instead of rendering it.
      const cookieUid = this.cookieUid()
      if (parsed.user_id != null && String(parsed.user_id) !== cookieUid) {
        window.localStorage.removeItem(this.storageKey)
        return
      }
      this.cache = parsed
      this.signedIn = true
      this._dispatch("user-list-state:loaded", { state: this.cache })
    } catch (err) {
      console.warn("user-list-state: storage read failed", err)
    }
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

  _onAuthSuccess() {
    this.refresh()
  }

  _onAuthSignout() {
    this._clearStorage()
    this.signedIn = false
    this.cache = null
    this.csrf = null
    this._dispatch("user-list-state:cleared")
  }
}

// Memoised at MODULE scope, not per controller instance. Turbo caches the
// mutated DOM and re-runs connect() on restore, so an instance-level promise
// would inject the script again on every Back navigation.
let loadPromise = null

const PENDING_REDIRECT_KEY = "tg:auth:pending-redirect"
const PENDING_VERIFICATION_KEY = "tg:auth:pending-verification"

export function loadFirebase(src) {
  if (loadPromise) return loadPromise

  loadPromise = new Promise((resolve, reject) => {
    if (window.__tgFirebase) {
      resolve(window.__tgFirebase)
      return
    }

    if (!src) {
      reject(new Error("firebase bundle src is missing; is data-authentication-firebase-src-value set?"))
      return
    }

    const script = document.createElement("script")
    script.src = src
    script.async = true

    script.onload = () => {
      if (window.__tgFirebase) {
        resolve(window.__tgFirebase)
      } else {
        reject(new Error("firebase bundle loaded but window.__tgFirebase is undefined"))
      }
    }

    script.onerror = () => {
      // Reset so a later attempt can retry -- e.g. the reader clicks Login
      // again after a transient network failure. Caching the rejection forever
      // would make one dropped request permanently break sign-in for the tab.
      loadPromise = null
      reject(new Error(`failed to load firebase bundle from ${src}`))
    }

    document.head.appendChild(script)
  })

  return loadPromise
}

// True once the bundle has been fetched by anyone on this page. Lets a caller
// act on a Firebase that is already here without triggering the download for
// a reader who never needed it.
export function firebaseLoaded() {
  return Boolean(window.__tgFirebase)
}

// True while a signInWithRedirect round trip is outstanding, so connect() knows
// to load Firebase eagerly and let getRedirectResult complete.
//
// Also matches Firebase's own sessionStorage key as belt-and-braces: if our
// write failed, theirs probably did too, but the flow is worth two chances.
export function pendingRedirect() {
  try {
    if (window.sessionStorage.getItem(PENDING_REDIRECT_KEY)) return true

    for (let i = 0; i < window.sessionStorage.length; i++) {
      if (window.sessionStorage.key(i)?.startsWith("firebase:pendingRedirect")) return true
    }
  } catch {
    // Storage blocked -- fall through.
  }

  return false
}

export function markPendingRedirect() {
  try { window.sessionStorage.setItem(PENDING_REDIRECT_KEY, "1") } catch { /* storage blocked */ }
}

export function clearPendingRedirect() {
  try { window.sessionStorage.removeItem(PENDING_REDIRECT_KEY) } catch { /* storage blocked */ }
}

// Set when Rails refuses an email/password sign-in with
// email_verification_required. The Firebase user is deliberately kept so
// resendVerification() has someone to send to, and this marker is what stops
// the widget from signing that user out as a stranger on the next page (it has
// a Firebase user and no tg_uid, which otherwise means "sign Firebase out").
//
// localStorage rather than sessionStorage because the reader is expected to go
// to their inbox, click the link, and come back -- often in a new tab. It never
// means signed in: there is no session and no tg_uid behind it.
//
// Mirrored in module memory so the same tab still behaves when storage is
// blocked (private mode, site data disabled); only the cross-reload half is
// lost then.
let pendingVerificationInMemory = false

export function markPendingVerification() {
  pendingVerificationInMemory = true
  try { window.localStorage.setItem(PENDING_VERIFICATION_KEY, "1") } catch { /* storage blocked */ }
}

export function clearPendingVerification() {
  pendingVerificationInMemory = false
  try { window.localStorage.removeItem(PENDING_VERIFICATION_KEY) } catch { /* storage blocked */ }
}

export function pendingVerification() {
  if (pendingVerificationInMemory) return true

  try {
    return Boolean(window.localStorage.getItem(PENDING_VERIFICATION_KEY))
  } catch {
    return false
  }
}

// Memoised at MODULE scope, not per controller instance. Turbo caches the
// mutated DOM and re-runs connect() on restore, so an instance-level promise
// would inject the script again on every Back navigation.
let loadPromise = null

const SIGNED_IN_KEY = "tg:auth:signed-in"
const PENDING_REDIRECT_KEY = "tg:auth:pending-redirect"

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

// Any hint that this browser has a signed-in user, or is mid sign-in.
//
// The signals fail in opposite directions, so the union is safer than either:
//   - tg_uid is a SESSION cookie, server-managed and authoritative, but it dies
//     on browser restart while Firebase's IndexedDB persistence survives.
//   - the localStorage flag survives restarts but is a client mirror that can
//     drift (a sign-out in another tab does not clear it in tabs that never
//     loaded Firebase).
//
// A false positive is cheap: load Firebase, get a null user, clear the flag,
// render Login. A false negative shows "Login" to a signed-in reader, which is
// the visible regression this exists to avoid. So: any hint wins.
export function likelySignedIn() {
  if (/(?:^|;\s*)tg_uid=/.test(document.cookie)) return true

  try {
    if (window.localStorage.getItem(SIGNED_IN_KEY)) return true
  } catch {
    // Storage blocked (private mode, site data disabled) -- fall through.
  }

  return pendingRedirect()
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

export function markSignedIn() {
  try { window.localStorage.setItem(SIGNED_IN_KEY, "1") } catch { /* storage blocked */ }
}

export function clearSignedInHint() {
  try { window.localStorage.removeItem(SIGNED_IN_KEY) } catch { /* storage blocked */ }
}

export function markPendingRedirect() {
  try { window.sessionStorage.setItem(PENDING_REDIRECT_KEY, "1") } catch { /* storage blocked */ }
}

export function clearPendingRedirect() {
  try { window.sessionStorage.removeItem(PENDING_REDIRECT_KEY) } catch { /* storage blocked */ }
}

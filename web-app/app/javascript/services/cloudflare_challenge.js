const originalFetch = window.fetch.bind(window)

const SAFE_METHODS = ["GET", "HEAD"]
const HANDOFF_KEY = "cf-challenge-handoff"
const HANDOFF_WINDOW_MS = 30000

function methodOf(input, init) {
  const method = init?.method ?? (input instanceof Request ? input.method : null)
  return (method ?? "GET").toUpperCase()
}

function headersOf(input, init) {
  const raw = init?.headers ?? (input instanceof Request ? input.headers : null)
  if (!raw) return new Headers()
  return raw instanceof Headers ? raw : new Headers(raw)
}

// Turbo's prefetch delegate silently discards a failed response, which is
// already the right outcome for a request the visitor never asked to make
// by clicking; navigating on a mere 100ms hover would be a worse surprise
// than the reload the wrapper would otherwise pick.
function isPrefetch(input, init) {
  return headersOf(input, init).get("X-Sec-Purpose") === "prefetch"
}

function isDocumentNavigation(input, init) {
  if (!SAFE_METHODS.includes(methodOf(input, init))) return false

  const headers = headersOf(input, init)
  if (headers.has("Turbo-Frame")) return false

  return (headers.get("Accept") ?? "").includes("text/html")
}

function recentlyHandedOff(url) {
  try {
    const last = JSON.parse(sessionStorage.getItem(HANDOFF_KEY))
    return last?.url === url && Math.abs(Date.now() - last.at) < HANDOFF_WINDOW_MS
  } catch {
    return false
  }
}

// sessionStorage throws in some privacy modes; a storage failure must never
// block the hand-off itself, so it degrades to losing only loop protection.
function recordHandOff(url) {
  try {
    sessionStorage.setItem(HANDOFF_KEY, JSON.stringify({url, at: Date.now()}))
  } catch {}
}

function handOffToNavigation(url, input, init) {
  if (recentlyHandedOff(url)) return false

  recordHandOff(url)

  if (isDocumentNavigation(input, init) && new URL(url).origin === window.location.origin) {
    window.location.assign(url)
  } else {
    window.location.reload()
  }

  return true
}

window.fetch = async (input, init) => {
  const response = await originalFetch(input, init)
  if (response.headers.get("cf-mitigated") !== "challenge") return response
  if (isPrefetch(input, init)) return response

  if (handOffToNavigation(response.url, input, init)) {
    return new Promise(() => {})
  }

  return response
}

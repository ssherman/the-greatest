const originalFetch = window.fetch.bind(window)

const SAFE_METHODS = ["GET", "HEAD"]

function methodOf(input, init) {
  const method = init?.method ?? (input instanceof Request ? input.method : null)
  return (method ?? "GET").toUpperCase()
}

function headersOf(input, init) {
  const raw = init?.headers ?? (input instanceof Request ? input.headers : null)
  if (!raw) return new Headers()
  return raw instanceof Headers ? raw : new Headers(raw)
}

function isDocumentNavigation(input, init) {
  if (!SAFE_METHODS.includes(methodOf(input, init))) return false

  const headers = headersOf(input, init)
  if (headers.has("Turbo-Frame")) return false

  return (headers.get("Accept") ?? "").includes("text/html")
}

const HANDOFF_KEY = "cf-challenge-handoff"
const HANDOFF_WINDOW_MS = 30000

function recentlyHandedOff(url) {
  try {
    const last = JSON.parse(sessionStorage.getItem(HANDOFF_KEY))
    return last?.url === url && Date.now() - last.at < HANDOFF_WINDOW_MS
  } catch {
    return false
  }
}

// sessionStorage throws in some privacy modes; a storage failure must never
// block the hand-off itself, so it degrades to losing only loop protection.
function recordHandOff(url) {
  try {
    sessionStorage.setItem(HANDOFF_KEY, JSON.stringify({url, at: Date.now()}))
  } catch {
    return
  }
}

function handOffToNavigation(url, input, init) {
  if (recentlyHandedOff(url)) return false

  recordHandOff(url)

  if (isDocumentNavigation(input, init)) {
    window.location.assign(url)
  } else {
    window.location.reload()
  }

  return true
}

window.fetch = async (input, init) => {
  const response = await originalFetch(input, init)
  if (response.headers.get("cf-mitigated") !== "challenge") return response

  if (handOffToNavigation(response.url, input, init)) {
    return new Promise(() => {})
  }

  return response
}

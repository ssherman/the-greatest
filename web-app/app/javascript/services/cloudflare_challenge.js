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

function handOffToNavigation(url, input, init) {
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

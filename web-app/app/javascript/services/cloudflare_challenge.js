const originalFetch = window.fetch.bind(window)

function handOffToNavigation(url) {
  window.location.assign(url)
  return true
}

window.fetch = async (input, init) => {
  const response = await originalFetch(input, init)
  if (response.headers.get("cf-mitigated") !== "challenge") return response

  if (handOffToNavigation(response.url)) {
    return new Promise(() => {})
  }

  return response
}

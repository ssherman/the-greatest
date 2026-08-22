import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="admin--markdown-preview"
//
// Debounced server-rendered Markdown preview. Posts the textarea's contents to
// the preview action, which returns a turbo-stream replacing #news_post_preview.
//
// Server-rendered on purpose: the preview then goes through the same
// Services::News::BodyRenderer the public page uses and cannot drift from it.
export default class extends Controller {
  static targets = ["source"]
  static values = { url: String, delay: { type: Number, default: 400 } }

  disconnect() {
    clearTimeout(this.timeout)
    this.abortController?.abort()
  }

  schedule() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.refresh(), this.delayValue)
  }

  async refresh() {
    // Supersede an in-flight request so a slow response cannot overwrite the
    // preview of newer text.
    this.abortController?.abort()
    this.abortController = new AbortController()

    const body = new FormData()
    body.append("news_post[body]", this.sourceTarget.value)

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          Accept: "text/vnd.turbo-stream.html",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body,
        signal: this.abortController.signal
      })

      if (!response.ok) return

      const html = await response.text()
      window.Turbo.renderStreamMessage(html)
    } catch (error) {
      if (error.name !== "AbortError") throw error
    }
  }
}

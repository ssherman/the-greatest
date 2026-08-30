import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="clipboard-copy"
export default class extends Controller {
  static targets = ["source", "button"]

  async copy(event) {
    const button = event?.currentTarget || this.buttonTarget
    const text = this.sourceTarget.value || this.sourceTarget.textContent
    try {
      await navigator.clipboard.writeText(text)
      this.showFeedback(button)
    } catch {
      // Fallback for older browsers
      this.sourceTarget.select()
      try {
        document.execCommand("copy")
      } finally {
        button.focus()
      }
      this.showFeedback(button)
    }
  }

  showFeedback(button = this.buttonTarget) {
    const originalText = button.textContent
    button.textContent = "Copied!"
    button.classList.add("btn-success")
    button.classList.remove("btn-primary")

    setTimeout(() => {
      button.textContent = originalText
      button.classList.remove("btn-success")
      button.classList.add("btn-primary")
    }, 2000)
  }
}

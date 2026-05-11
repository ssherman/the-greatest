import { Controller } from "@hotwired/stimulus"

// Singleton. Listens on window for "toast:show" events:
//   detail = { type: "success" | "error" | "info", message: String, ttl?: Number }
export default class extends Controller {
  connect() {
    this._onShow = this._onShow.bind(this)
    window.addEventListener("toast:show", this._onShow)
  }

  disconnect() {
    window.removeEventListener("toast:show", this._onShow)
  }

  _onShow(event) {
    const { type = "info", message = "", ttl = 4000 } = event.detail || {}
    if (!message) return

    const alert = document.createElement("div")
    alert.className = `alert alert-${type} shadow-lg`
    alert.setAttribute("role", "status")
    const span = document.createElement("span")
    span.textContent = message
    alert.appendChild(span)

    this.element.appendChild(alert)
    setTimeout(() => {
      alert.classList.add("opacity-0", "transition-opacity")
      setTimeout(() => alert.remove(), 300)
    }, ttl)
  }
}

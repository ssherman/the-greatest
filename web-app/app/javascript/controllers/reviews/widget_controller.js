import { Controller } from "@hotwired/stimulus"

// Per-book "Rate this book" control. The book page is edge-cached, so this ships
// identical for everyone and fills itself in from the uncached /review_state.
//
// Anonymous visitors never fetch: the endpoint requires auth, and clicking should
// open the login modal immediately rather than after a 401 round-trip. Gated on
// the tg_uid cookie, matching user_list_widget_controller.
export default class extends Controller {
  static targets = ["button", "label", "stars"]
  static values = {
    reviewableType: String,
    reviewableId: String,
    url: { type: String, default: "/review_state" }
  }

  connect() {
    this.review = null
    this.csrfToken = null
    if (this.cookieUid()) this.load()
  }

  cookieUid() {
    const m = document.cookie.match(/(?:^|;\s*)tg_uid=([^;]+)/)
    return m ? decodeURIComponent(m[1]) : null
  }

  async load() {
    const params = new URLSearchParams({
      reviewable_type: this.reviewableTypeValue,
      reviewable_id: this.reviewableIdValue
    })

    let response
    try {
      response = await fetch(`${this.urlValue}?${params}`, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
    } catch (err) {
      console.warn("reviews--widget: network error", err)
      return
    }

    if (!response.ok) return

    const data = await response.json()
    this.review = data.review
    this.csrfToken = data.csrf_token || null
    this.applyToken(this.csrfToken)
    this.render()
  }

  // Also patch the page meta tag: the cached page's token belongs to whoever
  // populated the cache, so any other Turbo request on this page is stale too.
  applyToken(token) {
    if (!token) return
    const meta = document.querySelector('meta[name="csrf-token"]')
    if (meta) meta.setAttribute("content", token)
  }

  render() {
    if (!this.hasLabelTarget) return
    this.labelTarget.textContent = this.review ? "Edit your review" : "Rate this book"
    if (this.hasStarsTarget) this.starsTarget.classList.toggle("hidden", !this.review)
  }

  open(event) {
    event.preventDefault()

    if (!this.cookieUid()) {
      const loginModal = document.getElementById("login_modal")
      if (loginModal && loginModal.showModal) loginModal.showModal()
      return
    }

    window.dispatchEvent(new CustomEvent("reviews-modal:open", {
      detail: {
        reviewableType: this.reviewableTypeValue,
        reviewableId: this.reviewableIdValue,
        review: this.review,
        csrfToken: this.csrfToken
      }
    }))
  }
}

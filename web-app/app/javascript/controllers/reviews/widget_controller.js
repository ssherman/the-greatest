import { Controller } from "@hotwired/stimulus"

// Per-book "Rate this book" control. The book page is edge-cached, so this ships
// identical for everyone and fills itself in from the uncached /review_state.
//
// Anonymous visitors never fetch: the endpoint requires auth, and clicking should
// open the login modal immediately rather than after a 401 round-trip. Gated on
// the tg_uid cookie, matching user_list_widget_controller.
export default class extends Controller {
  static targets = ["label", "stars"]
  static values = {
    reviewableType: String,
    reviewableId: String,
    url: { type: String, default: "/review_state" }
  }

  connect() {
    this.review = null
    this.csrfToken = null
    this._inflightLoad = null
    if (this.cookieUid()) this.load()
  }

  cookieUid() {
    const m = document.cookie.match(/(?:^|;\s*)tg_uid=([^;]+)/)
    return m ? decodeURIComponent(m[1]) : null
  }

  // Coalesces concurrent callers -- the eager fetch kicked off from connect() and
  // a click that lands before it resolves -- onto a single in-flight request.
  // Same pattern as user_list_state_controller#ensureCsrf. open() awaits this, so
  // the modal is only ever handed a real (or an honestly-failed) token, never the
  // pre-fetch null: without it, a click that beats the fetch would dispatch
  // reviews-modal:open with csrfToken still null, the modal would bake that empty
  // value into its hidden field, and Rails would reject the save with no way for
  // the user to recover short of reloading the page.
  load() {
    if (this._inflightLoad) return this._inflightLoad
    this._inflightLoad = this._doLoad().finally(() => {
      this._inflightLoad = null
    })
    return this._inflightLoad
  }

  async _doLoad() {
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
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = this.review ? "Edit your review" : "Rate this book"
    }
    this.renderStars()
  }

  // Reviews::WidgetComponent always renders Reviews::StarsComponent, even with no
  // review (rating 0, clipped to an empty fill) -- that keeps the cached HTML
  // identical for every visitor. So hydration only ever adjusts the fill width and
  // the accessible name here; it never reveals or hides the element, which would
  // otherwise flash an empty box the instant the label switches to "Edit your
  // review" and before this fetch has actually delivered a rating.
  renderStars() {
    if (!this.hasStarsTarget) return

    const rating = this.review ? this.review.rating : 0
    const clamped = Math.max(0, Math.min(5, rating))
    const fillPercentage = ((clamped / 5) * 100).toFixed(1)

    const fill = this.starsTarget.querySelector('[data-testid="stars-fill"]')
    if (fill) fill.style.width = `${fillPercentage}%`

    const img = this.starsTarget.querySelector('[role="img"]')
    if (img) {
      img.setAttribute("aria-label",
        this.review ? `Your rating: ${rating} out of 5 stars` : "Not yet rated")
    }
  }

  async open(event) {
    event.preventDefault()

    if (!this.cookieUid()) {
      const loginModal = document.getElementById("login_modal")
      if (loginModal && loginModal.showModal) loginModal.showModal()
      return
    }

    await this.load()

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

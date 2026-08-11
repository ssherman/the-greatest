import { Controller } from "@hotwired/stimulus"

// Singleton rating/review dialog. Rendered empty into cached HTML, so every
// user-specific part -- form action, method override, field values and the CSRF
// token -- is set here before the dialog opens.
export default class extends Controller {
  static targets = [
    "form", "token", "methodField", "reviewableType", "reviewableId",
    "rating", "title", "body", "star", "remove", "save", "heading", "error"
  ]

  connect() {
    this._onOpen = this._onOpen.bind(this)
    window.addEventListener("reviews-modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("reviews-modal:open", this._onOpen)
  }

  _onOpen(event) {
    const { reviewableType, reviewableId, review, csrfToken } = event.detail || {}

    this.reviewableTypeTarget.value = reviewableType || ""
    this.reviewableIdTarget.value = reviewableId || ""

    // Rails validates the submitted authenticity_token parameter for a form post.
    // The value baked into the cached page is stale or absent, so set it here
    // rather than depending on Turbo attaching a header.
    this.tokenTarget.value = csrfToken || ""

    if (review) {
      this.formTarget.action = `/reviews/${review.id}`
      this.methodFieldTarget.value = "patch"
      this.headingTarget.textContent = "Edit your review"
      this.titleTarget.value = review.title || ""
      this.bodyTarget.value = review.body || ""
      this.setRatingValue(review.rating)
      this.removeTarget.classList.remove("hidden")
    } else {
      this.formTarget.action = "/reviews"
      this.methodFieldTarget.value = "post"
      this.headingTarget.textContent = "Rate this book"
      this.titleTarget.value = ""
      this.bodyTarget.value = ""
      this.setRatingValue(null)
      this.removeTarget.classList.add("hidden")
    }

    this.hideError()
    if (this.element.showModal) this.element.showModal()
  }

  setRating(event) {
    const value = parseInt(event.currentTarget.dataset.rating, 10)
    this.setRatingValue(value)
  }

  setRatingValue(value) {
    this.ratingTarget.value = value || ""
    this.starTargets.forEach((star) => {
      const starValue = parseInt(star.dataset.rating, 10)
      const on = value != null && starValue <= value
      star.setAttribute("aria-pressed", on ? "true" : "false")
      star.querySelectorAll("svg").forEach((svg) => svg.classList.toggle("fill-current", on))
    })
  }

  remove() {
    this.methodFieldTarget.value = "delete"
    this.formTarget.requestSubmit()
  }

  close() {
    if (this.element.close) this.element.close()
  }

  // Turbo reports the outcome here. A rating is required, so a save with no stars
  // comes back 422 and the dialog stays open with a message.
  submitted(event) {
    const success = event.detail && event.detail.success
    if (!success) {
      this.showError("Pick a rating from 1 to 5 before saving.")
      return
    }

    this.close()
    window.dispatchEvent(new CustomEvent("toast:show", {
      detail: {
        type: "success",
        message: "Saved. It will appear on this page shortly."
      }
    }))
  }

  showError(message) {
    this.errorTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
  }

  hideError() {
    this.errorTarget.textContent = ""
    this.errorTarget.classList.add("hidden")
  }
}

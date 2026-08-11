import { Controller } from "@hotwired/stimulus"

// Singleton rating/review dialog. Rendered empty into cached HTML, so every
// user-specific part -- form action, method override, field values and the CSRF
// token -- is set here before the dialog opens.
export default class extends Controller {
  static targets = [
    "form", "token", "methodField", "reviewableType", "reviewableId",
    "rating", "title", "body", "star", "remove", "heading", "error"
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
    // rather than depending on Turbo attaching a header. widget_controller
    // guarantees this is either a real, freshly-fetched token or an honestly
    // empty one (never the in-flight placeholder) -- see its load()/open().
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

  // The one field the server actually requires. Checked on the form's own
  // "submit" event, which fires (and can be defaultPrevented) before Turbo's
  // document-level listener ever sees it -- Turbo only intercepts a bubbled
  // submit that still has defaultPrevented false -- so a missing rating never
  // reaches the network at all, and submitted() never has to guess that a 422
  // means this. A delete carries no rating and skips this check: remove() drives
  // its own requestSubmit() through this same form with methodField "delete".
  validate(event) {
    if (this.methodFieldTarget.value === "delete") return
    if (this.ratingTarget.value) return

    event.preventDefault()
    this.showError("Pick a rating from 1 to 5 before saving.")
  }

  remove() {
    this.methodFieldTarget.value = "delete"
    this.formTarget.requestSubmit()
  }

  close() {
    if (this.element.close) this.element.close()
  }

  // Turbo reports the outcome here. validate() already caught the one failure
  // this dialog can diagnose locally (no rating), so a failure arriving here is a
  // genuine server-side or network problem: a stale/rejected CSRF token, a 500, a
  // plain network drop, or the review having been deleted from another tab. Only
  // the last of those is distinct enough to name from the client; the rest
  // collapse into one honest "try again" rather than a guess that might be wrong.
  submitted(event) {
    const { success, fetchResponse } = event.detail || {}

    if (success) {
      const wasRemoval = this.methodFieldTarget.value === "delete"
      this.close()
      window.dispatchEvent(new CustomEvent("toast:show", {
        detail: {
          type: "success",
          message: wasRemoval
            ? "Removed."
            : "Saved. It will appear on this page shortly."
        }
      }))
      return
    }

    this.showError(this.errorMessageFor(fetchResponse))
  }

  // fetchResponse is undefined for a plain network failure -- turbo:submit-end
  // still fires with success: false, but carries detail.error instead. Where a
  // status does exist, a 404 means the review was already removed elsewhere.
  errorMessageFor(fetchResponse) {
    if (fetchResponse && fetchResponse.statusCode === 404) {
      return "This review could not be found. It may have already been removed."
    }
    return "Something went wrong. Please try again."
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

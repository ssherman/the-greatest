import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="reviews--my-reviews"
//
// Opens the shared review dialog (Reviews::ModalComponent, rendered once into
// every books layout -- see app/views/layouts/books/application.html.erb) from
// a /my/reviews row, and reloads the page once the dialog reports a successful
// save or removal.
//
// Unlike the book page, /my/reviews is never cached (MyReviewsController calls
// prevent_caching), so the CSRF token sitting in the page's own <meta> tag is
// always the real one for this request. There is no /review_state fetch here
// the way reviews--widget needs on the cached book page.
export default class extends Controller {
  open(event) {
    const row = event.currentTarget.dataset
    const reviewId = row.reviewId

    window.dispatchEvent(new CustomEvent("reviews-modal:open", {
      detail: {
        reviewableType: row.reviewableType,
        reviewableId: row.reviewableId,
        csrfToken: document.querySelector('meta[name="csrf-token"]')?.content || "",
        review: reviewId
          ? { id: reviewId, rating: Number(row.rating), title: row.title, body: row.body }
          : null
      }
    }))
  }

  // ReviewsController#render_widget_and_summary streams turbo-stream updates
  // targeting review_widget, review_summary_line and review_card -- all
  // book-page element ids that do not exist on /my/reviews, so Turbo silently
  // no-ops on every one of them here. Reload instead: it recomputes the row,
  // the profile strip's bar chart and the counts server-side, so nothing on
  // this page can drift out of step with what was just written.
  //
  // Listening on @document (see the view) is required -- the dialog is a
  // layout-level sibling rendered after </footer>, outside this controller's
  // own container -- but turbo:submit-end also bubbles here from this page's
  // own GET search form. Turbo dispatches turbo:submit-end unconditionally
  // in FormSubmission#requestFinished, target: this.formElement, for every
  // submission including safe (GET) ones, and reports success: true for a
  // successful search exactly as for the dialog's save. So a reload here has
  // to be scoped to submits that actually came from the dialog, or searching
  // reloads the pre-search URL and silently discards the query.
  submitted(event) {
    if (!event.detail?.success) return
    if (!event.target.closest?.("#review_modal")) return
    window.location.reload()
  }
}

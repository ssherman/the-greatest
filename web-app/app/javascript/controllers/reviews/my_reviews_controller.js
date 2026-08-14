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
  submitted(event) {
    if (!event.detail?.success) return
    window.location.reload()
  }
}

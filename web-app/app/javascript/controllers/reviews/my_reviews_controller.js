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
  // Two submits legitimately reload: the dialog's own save/remove, and a row's
  // Delete button. Everything else that bubbles here -- today the GET search
  // form, tomorrow anything else added to this page -- must not, so this is an
  // allowlist of two specific origins rather than a "not the search form" test.
  // The difference matters: a negative test silently starts reloading the next
  // form someone adds.
  submitted(event) {
    const form = event.target
    const fromDialog = form.closest?.("#review_modal")
    const fromRowDelete = form.matches?.("[data-my-reviews-delete]")
    if (!fromDialog && !fromRowDelete) return

    if (!event.detail?.success) {
      // The dialog has its own inline error line and reports failures itself
      // (reviews--modal#submitted), so leave those alone. A row's Delete has no
      // such surface: ReviewsController answers every deliberate failure with an
      // EMPTY turbo stream carrying only a status, so without this the page sits
      // there unchanged and the button looks broken. The 429 is not theoretical
      // -- the write limit is 20 a minute and DELETE counts against it, which a
      // per-row button invites you to hit while clearing out old ratings.
      if (fromRowDelete) {
        window.dispatchEvent(new CustomEvent("toast:show", {
          detail: { type: "error", message: this.deleteErrorMessage(event.detail) }
        }))
      }
      return
    }

    // Deleting the only row on a paged URL empties that page, and
    // PathBasedPagination#pagy_path raises RecordNotFound past the last page --
    // so reloading /my/reviews/page/4 after removing its last review would 404
    // a user who just did something entirely valid. Drop the page segment and
    // keep the filters instead.
    if (fromRowDelete && form.dataset.myReviewsDeleteLast === "true") {
      const url = new URL(window.location.href)
      url.pathname = url.pathname.replace(/\/page\/\d+$/, "")
      window.location.assign(url.toString())
      return
    }

    window.location.reload()
  }

  // Only statuses a reader can act on differently are named. Everything else
  // collapses into one honest "it did not happen" rather than a guess that might
  // be wrong -- and crucially it says the review was NOT deleted, because the row
  // is still on screen and the ambiguous case is someone assuming it worked.
  // fetchResponse is undefined for a plain network drop; turbo:submit-end still
  // fires with success: false and carries detail.error instead.
  deleteErrorMessage(detail) {
    switch (detail?.fetchResponse?.statusCode) {
      case 404:
        return "That review was already removed."
      case 429:
        return "Too many changes at once. Wait a minute, then try again."
      case 401:
        return "Your session expired. Sign in again to delete this review."
      default:
        return "Something went wrong and the review was not deleted. Please try again."
    }
  }
}

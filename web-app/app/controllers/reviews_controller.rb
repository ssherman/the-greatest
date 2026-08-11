class ReviewsController < ApplicationController
  include Cacheable

  before_action :prevent_caching
  before_action :require_signed_in!

  # Same allowlist rule as ReviewStateController: reviewable_type is user input,
  # and a visitor must not be able to attach a review to an arbitrary class.
  REVIEWABLE_TYPES = ["Books::Book"].freeze

  # A Turbo-submitted form that receives a non-2xx response without a
  # turbo-stream content type gets its body rendered as a whole new page --
  # and `head` sends an empty body, so the user's page goes blank. Every
  # deliberate failure here is therefore an EMPTY turbo stream carrying the
  # right status, never `head`. The modal's Stimulus controller
  # (reviews/modal_controller.js#submitted) reads the status off
  # turbo:submit-end and renders the user-facing message itself -- the server
  # must not also write one, or the two would fight over the same element.
  rescue_from Pundit::NotAuthorizedError do
    render turbo_stream: [], status: :forbidden
  end

  # ApplicationController's inherited RecordNotFound handler serves
  # public/404.html -- a real HTML body on a non-2xx status, the exact
  # page-destroying shape described above, just triggered by a stale id
  # (the review was deleted from another tab) instead of by `head`. The
  # modal's submitted() -> errorMessageFor already special-cases a 404
  # ("This review could not be found...") specifically for that scenario, so
  # it must arrive as a turbo stream, not the site's 404 page.
  rescue_from ActiveRecord::RecordNotFound do
    render turbo_stream: [], status: :not_found
  end

  # Rails' own unhandled response to this exception renders public/422.html --
  # again an HTML body on a non-2xx status. Reachable in production even
  # though the form always submits *some* token: widget_controller#open
  # depends on a freshly-fetched token from /review_state, and if that fetch
  # errors or returns early, the modal (see reviews/modal_controller.js#_onOpen)
  # sets the field to "" rather than leaving the cached page's stale <meta>
  # value in place. That is the "stale/rejected CSRF token" case
  # modal_controller.js#submitted's own comment names. allow_forgery_protection
  # is false in the test environment (config/environments/test.rb), so no
  # request spec can raise this here -- verified instead by reading that
  # rescue_from takes precedence over Rails' default exceptions_app handling
  # for any subclass of StandardError raised inside the action, which
  # InvalidAuthenticityToken is.
  rescue_from ActionController::InvalidAuthenticityToken do
    render turbo_stream: [], status: :unprocessable_entity
  end

  def create
    reviewable = find_reviewable(params.dig(:review, :reviewable_type), params.dig(:review, :reviewable_id))
    return render turbo_stream: [], status: :bad_request if reviewable.nil?

    @review = current_user.reviews.new(review_params.merge(reviewable: reviewable))
    authorize @review, policy_class: ReviewPolicy

    if @review.save
      purge_cached_page(@review)
      render_widget_and_summary(reviewable, @review)
    else
      render turbo_stream: [], status: :unprocessable_entity
    end
  end

  def update
    @review = Review.find(params[:id])
    authorize @review, policy_class: ReviewPolicy

    if @review.update(review_params)
      purge_cached_page(@review)
      render_widget_and_summary(@review.reviewable, @review)
    else
      render turbo_stream: [], status: :unprocessable_entity
    end
  end

  def destroy
    @review = Review.find(params[:id])
    authorize @review, policy_class: ReviewPolicy
    reviewable = @review.reviewable

    @review.destroy
    purge_cached_page(@review)
    render_widget_and_summary(reviewable, nil)
  end

  private

  # ApplicationController#require_signed_in! redirects for any non-JSON format --
  # every other caller in the app is JSON-only, so that branch never mattered
  # before. For a Turbo Stream form submission it's wrong: fetch follows the
  # redirect on its own, and Turbo treats the resulting 200 HTML response as a
  # full-page replacement -- the same "page goes away" failure the class
  # comment above describes for `head`, just arriving one hop later. Every
  # unauthenticated response here must be a real 401 turbo stream so the
  # modal's Stimulus controller can read the status off turbo:submit-end.
  def require_signed_in!
    return if current_user

    render turbo_stream: [], status: :unauthorized
  end

  # Only rating, title and body are assignable. reviewable is resolved from the
  # allowlist, and user comes from the session -- never from params.
  def review_params
    params.require(:review).permit(:rating, :title, :body)
  end

  def find_reviewable(type, id)
    return nil unless REVIEWABLE_TYPES.include?(type.to_s)

    type.to_s.constantize.find_by(id: id)
  end

  # Explicit, not a model callback: an after_commit making an external HTTP call
  # is invisible to its callers and would fire from rake tasks and importers.
  # Increment 5's admin destroy is the next write path that will need this line.
  def purge_cached_page(review)
    Reviews::PurgeCachedPageJob.perform_async(review.reviewable_type, review.reviewable_id)
  end

  # SummaryRecalculator runs in Review's after_commit, so the association cached
  # on the reviewable is stale by now. Load the row fresh.
  def render_widget_and_summary(reviewable, review)
    summary = ReviewSummary.find_by(reviewable_type: reviewable.class.name, reviewable_id: reviewable.id)

    # `update`, NOT `replace`. `replace` swaps the element carrying the id, so the
    # wrapper -- and with it the Turbo Stream target -- would vanish after the first
    # save and every later save would land nowhere. `update` replaces the wrapper's
    # contents and leaves the wrapper in place. This also matters for the summary
    # line, whose component renders nothing at all when a book's last review is
    # removed: with `replace` the target would be gone for good.
    render turbo_stream: [
      turbo_stream.update(
        "review_widget",
        Reviews::WidgetComponent.new(reviewable: reviewable, review: review).render_in(view_context)
      ),
      turbo_stream.update(
        "review_summary_line",
        Reviews::SummaryLineComponent.new(summary: summary).render_in(view_context)
      )
    ]
  end
end

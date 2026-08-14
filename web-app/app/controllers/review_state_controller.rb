class ReviewStateController < ApplicationController
  include Cacheable
  include JsonErrorResponses

  # Per-user state must never be cached at CloudFlare or in the browser.
  before_action :prevent_caching
  before_action :require_signed_in!

  # GET /review_state?reviewable_type=Books::Book&reviewable_id=:id
  #
  # Returns ONE record, unlike /user_list_state which returns every membership the
  # user has. The heaviest rater has 2,331 ratings; shipping all of them to render
  # a single book page would be pure waste.
  def show
    type = params[:reviewable_type].to_s
    id = params[:reviewable_id].to_s

    # reviewable_type arrives from the query string; Reviews::Registry is the
    # allowlist that stops a visitor naming an arbitrary class.
    if !Reviews::Registry.allowed?(type) || id.blank?
      return render json: {error: {code: "bad_request", message: "Unknown reviewable"}},
        status: :bad_request
    end

    review = current_user.reviews.find_by(reviewable_type: type, reviewable_id: id)

    render json: {
      review: review && serialize(review),
      # The cached HTML's <meta name="csrf-token"> belongs to whoever rendered the
      # cache (or no one). Issue a fresh per-session token here for client-side
      # mutations. This endpoint is never cached.
      csrf_token: form_authenticity_token
    }
  end

  private

  # The stored body is exactly what the author typed -- BodySanitizer.call sanitizes
  # but never transforms, so there is no generated markup to undo before putting it
  # back in a textarea.
  def serialize(review)
    {
      id: review.id,
      rating: review.rating,
      title: review.title,
      body: review.body
    }
  end
end

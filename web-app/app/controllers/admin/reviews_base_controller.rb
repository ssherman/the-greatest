# Generic admin surface for reviews: index and destroy only. No approval queue --
# nothing gates publishing.
#
# Domain-agnostic on purpose: reviews exist only for books today, but nothing
# here may assume that -- later increments add music and games. Each domain
# supplies its own routable subclass (see Admin::Books::ReviewsController) that
# fills in reviewable_class, reviewable_includes and reviews_path, and mixes in
# Admin::DomainScopedAuth itself, because admin auth is domain-scoped through
# that concern.
class Admin::ReviewsBaseController < Admin::BaseController
  before_action :require_domain_write!, only: [:destroy]

  def index
    scope = Review.where(reviewable_type: reviewable_class.name)
      .includes(:user)
      .preload(reviewable: reviewable_includes)

    # Written reviews by default: of ~128,000 rows only ~16,000 carry text, so an
    # unfiltered index is overwhelmingly rating-only noise.
    @written_only = params[:written] != "all"
    scope = scope.where.not(body: nil) if @written_only

    @search_query = params[:q].presence
    scope = apply_search(scope, @search_query) if @search_query

    @pagy, @reviews = pagy(scope.order(created_at: :desc, id: :desc), limit: 50)
  end

  def destroy
    review = Review.find(params[:id])
    reviewable_type = review.reviewable_type
    reviewable_id = review.reviewable_id
    review.destroy!

    # Explicit, exactly as in ReviewsController: an after_commit making an
    # external HTTP call would be invisible to its callers and would fire from
    # rake tasks and importers. This is the write path that comment predicted.
    ::Reviews::PurgeCachedPageJob.perform_async(reviewable_type, reviewable_id)

    redirect_to reviews_path, notice: "Review deleted."
  end

  private

  # reviewable_class.review_text_search applies a title/author EXISTS match to
  # a scope already joined to the reviewable's table -- see Books::Book. Both
  # branches below are built from the SAME joined relation (rather than one
  # joined and one not) specifically so `.or` sees identical joins_values on
  # both sides; ActiveRecord's structural-compatibility check for `.or` only
  # relaxes when a value is flatly *unset* on one side (nil), not when the two
  # sides disagree, so deriving the two branches from different starting
  # points would raise "Relation passed to #or must be structurally
  # compatible". Verified directly against this schema before relying on it.
  def apply_search(scope, term)
    joined = scope.joins("INNER JOIN #{reviewable_class.table_name} ON #{reviewable_class.table_name}.id = reviews.reviewable_id")
    pattern = "%#{User.sanitize_sql_like(term)}%"

    reviewable_class.review_text_search(joined, term).or(
      joined.where(user_id: User.where("email ILIKE :p OR display_name ILIKE :p", p: pattern))
    )
  end

  def reviewable_class
    raise NotImplementedError, "Subclass must implement reviewable_class"
  end

  def reviewable_includes
    raise NotImplementedError, "Subclass must implement reviewable_includes"
  end

  def reviews_path
    raise NotImplementedError, "Subclass must implement reviews_path"
  end
end

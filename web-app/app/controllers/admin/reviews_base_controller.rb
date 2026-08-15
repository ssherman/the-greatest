# Generic admin surface for reviews: index and destroy only. No approval queue --
# nothing gates publishing.
#
# Domain-agnostic on purpose: reviews exist only for books today, but nothing
# here may assume that -- later increments add music and games. Each domain
# supplies its own routable subclass (see Admin::Books::ReviewsController) that
# fills in reviewable_class, reviewable_includes and reviews_index_path, and
# mixes in Admin::DomainScopedAuth itself, because admin auth is domain-scoped
# through that concern.
#
# reviews_index_path, not reviews_path: the global route helper `reviews_path`
# already names the public POST /reviews create endpoint (see routes.rb). A
# private controller method of that same name would shadow it -- inertly today
# since Ruby resolves the controller's own instance method first, but it costs
# nothing to remove the trap.
class Admin::ReviewsBaseController < Admin::BaseController
  before_action :require_domain_write!, only: [:destroy]

  # Every param a link on this page ever needs to preserve, mirroring
  # MyReviewsController::FILTER_KEYS on the public side -- sliced rather than
  # excluding an unwanted set, so an arbitrary visitor-invented query param is
  # never echoed back into every link on the page. "page" is deliberately
  # absent: switching the written/all toggle or searching should land back on
  # page 1, not carry a stale page number to a shorter result set.
  FILTER_KEYS = %w[q written].freeze

  helper_method :filter_params, :reviews_index_path, :review_detail_path, :reviewable_label

  def index
    scope = Review.where(reviewable_type: reviewable_class.name)
      .includes(:user)
      .preload(reviewable: reviewable_includes)

    # Written reviews by default: of ~128,000 rows only ~16,000 carry text, so an
    # unfiltered index is overwhelmingly rating-only noise. Review.with_body is
    # the same scope the model itself carries the empty-string-body rationale
    # for -- reuse it rather than re-deriving `where.not(body: nil)` here.
    @written_only = params[:written] != "all"
    scope = scope.with_body if @written_only

    # params[:q] arrives as an Array for a request like ?q[]=war -- to_s first
    # so User.sanitize_sql_like always receives a String. Reviews::MyReviewsQuery
    # hit the identical shape with ?rating[]=1 earlier on this branch.
    @search_query = params[:q].to_s.presence
    scope = apply_search(scope, @search_query) if @search_query

    @pagy, @reviews = pagy(scope.order(created_at: :desc, id: :desc), limit: 50)
  end

  def destroy
    # Scoped to this controller's reviewable_type, exactly like index -- NOT a
    # bare Review.find. require_domain_write! only proves write access to the
    # domain this controller is mounted under; without this scope a books
    # editor could delete a music or games review by id, and because the purge
    # is enqueued with the victim's own reviewable_type, the cross-domain
    # deletion would propagate cleanly instead of erroring. Not exploitable
    # today (the registry holds only Books::Book) but this base class exists
    # precisely so other domains subclass it.
    review = Review.where(reviewable_type: reviewable_class.name).find(params[:id])
    reviewable_type = review.reviewable_type
    reviewable_id = review.reviewable_id
    review.destroy!

    # Explicit, exactly as in ReviewsController: an after_commit making an
    # external HTTP call would be invisible to its callers and would fire from
    # rake tasks and importers. This is the write path that comment predicted.
    ::Reviews::PurgeCachedPageJob.perform_async(reviewable_type, reviewable_id)

    redirect_to reviews_index_path, notice: "Review deleted."
  end

  private

  # reviewable_class.review_text_search applies a title/author EXISTS match to
  # a scope already joined to the reviewable's table -- see Books::Book. Both
  # branches below are built from the SAME joined relation (rather than one
  # joined and one not), so their joins_values are the same array on both
  # sides of the `.or`.
  #
  # This is NOT the only shape that would pass: ActiveRecord's structural-
  # compatibility check for `.or` (see structurally_incompatible_values_for in
  # activerecord's query_methods.rb) relaxes whenever a value is flatly
  # *unset* on one side (nil, meaning that relation method was never called),
  # so a version with one branch joined and the other left bare also happens
  # to pass -- verified directly against this schema. But that passes only by
  # accident of which values happen to be nil rather than merely different,
  # which is a fragile thing to depend on deliberately. Building both branches
  # from the same `joined` relation makes the two sides compatible on the
  # merits, independent of that relaxation rule.
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

  def reviews_index_path(params = {})
    raise NotImplementedError, "Subclass must implement reviews_index_path"
  end

  # review_detail_path, not review_path: the global route helper `review_path`
  # already names the public PATCH /reviews/:id endpoint (routes.rb), so a
  # helper_method of that name would shadow it for every admin view. Same trap,
  # and same reasoning, as reviews_index_path vs. the public reviews_path above.
  def review_detail_path(review)
    raise NotImplementedError, "Subclass must implement review_detail_path"
  end

  # Titles one column in one admin table. Deliberately a controller string and
  # not a method on the reviewable model: what a books admin calls this column
  # is not a property of a book.
  def reviewable_label
    raise NotImplementedError, "Subclass must implement reviewable_label"
  end

  def filter_params(overrides = {})
    request.query_parameters.slice(*FILTER_KEYS).merge(overrides.stringify_keys).compact
  end
end

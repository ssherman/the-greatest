# Personal ratings library. Global route like MyListsController: one path serves
# every host and the layout comes from Current.domain at request time.
class MyReviewsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination
  include DomainLayout

  layout :resolve_layout

  before_action :require_signed_in!
  before_action :prevent_caching

  PER_PAGE = 25

  SORT_LABELS = {
    "recent" => "Recently rated",
    "rating_high" => "My rating: high to low",
    "rating_low" => "My rating: low to high",
    "rank" => "Site rank",
    "title" => "Title A–Z"
  }.freeze

  helper_method :sort_labels, :filter_params, :hidden_filter_params

  def index
    @reviewable_classes = Reviews::Registry.classes_for(Current.domain)
    # Not an empty state: a domain with no reviewable types has no such page at
    # all, and rendering one would ship a permanently blank /my/reviews on the
    # music and games hosts.
    raise ActiveRecord::RecordNotFound if @reviewable_classes.empty?

    @reviewable_class = resolve_reviewable_class
    @query = Reviews::MyReviewsQuery.new(user: current_user, reviewable_class: @reviewable_class, params: params)
    @stats = Reviews::MyReviewsStats.new(user: current_user, reviewable_class: @reviewable_class)

    # preload, NOT includes: the query carries string joins, and includes would
    # let Rails choose eager_load, which raises EagerLoadPolymorphicError on a
    # polymorphic association. Every row here is one reviewable type, so a
    # grouped preload is both valid and cheaper.
    @pagy, @reviews = pagy_path(
      @query.call.preload(reviewable: @reviewable_class.review_row_includes),
      limit: PER_PAGE
    )
  end

  private

  # The requested type must be one this domain actually offers; anything else
  # falls back to the first rather than 404ing, so a stale bookmark still lands
  # somewhere useful.
  def resolve_reviewable_class
    requested = params[:reviewable].to_s
    @reviewable_classes.find { |klass| klass.name == requested } || @reviewable_classes.first
  end

  # Every control must preserve the OTHER filters -- a sort link inside a rating
  # filter has to keep the rating. `page` is always dropped: a user on page 7 who
  # filters to 5-star would otherwise land on an empty page 7, which
  # PathBasedPagination turns into a 404.
  def filter_params(overrides = {})
    request.query_parameters.except("page").merge(overrides.stringify_keys).compact
  end

  def hidden_filter_params
    filter_params.except("q")
  end

  def sort_labels
    SORT_LABELS
  end
end

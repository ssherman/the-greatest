class Books::BrowseController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :redirect_to_canonical_form, :cache_for_index_page, except: :search
  # Hit as the reader types and keyed by a free-text query: never edge-cached.
  before_action :prevent_caching, only: :search
  before_action :find_ranking_configuration

  TITLES = {
    "genre" => "Book Genres",
    "audience" => "Books by Audience",
    "location" => "Book Settings",
    "subject" => "Book Subjects"
  }.freeze

  QUERY_FORM_KEYS = %w[filter sort page].freeze

  def categories
    @type = Books::BrowseQuery.normalized_type(params[:filter])
    @sort = Books::BrowseQuery.normalized_sort(params[:sort])
    # A sorted variant is NOT the same result set reordered -- this list
    # paginates at 120, so /sorted-by/name page 1 and the canonical it points at
    # share no rows. noindex, follow keeps the human toggle and the link equity
    # without minting ~104 thin hubs.
    @indexable = (@sort == Books::BrowseQuery::SORTS.first)
    @page_title = TITLES.fetch(@type)
    # The sort is deliberately dropped: a sort variant is the same result set
    # reordered, so it canonicalizes to the unsorted path.
    @canonical_path = Books::BrowsePath.call(axis: :categories, type: @type, page: page_number)

    @pagy, @records = pagy_path(
      Books::BrowseQuery.categories(ranking_configuration: @ranking_configuration, type: @type, sort: @sort),
      limit: 120
    )
    @chains = Books::CategoryChains.call(@records)
  end

  def search
    @type = Books::BrowseQuery.normalized_type(params[:filter])
    # params[:q] can arrive as an array or hash (?q[]=x); only a string is a query.
    @query = params[:q].is_a?(String) ? params[:q] : ""
    # What the status line quotes and what is searched: trimmed and capped.
    @term = @query.strip.first(Books::BrowseQuery::SEARCH_MAX_LENGTH)
    @indexable = false
    @page_title = "Search categories"
    @records = Books::BrowseQuery.search(
      ranking_configuration: @ranking_configuration, query: @query, type: @type
    ).to_a
    @chains = Books::CategoryChains.call(@records)
  end

  def countries
    @sort = Books::BrowseQuery.normalized_sort(params[:sort])
    @indexable = (@sort == Books::BrowseQuery::SORTS.first)
    @page_title = "Book Origins"
    @canonical_path = Books::BrowsePath.call(axis: :countries, page: page_number)

    @pagy, @records = pagy_path(
      Books::BrowseQuery.countries(ranking_configuration: @ranking_configuration, sort: @sort),
      limit: 120
    )
  end

  private

  # Any request whose URL is not the one BrowsePath would build for its own
  # params folds into that URL with a single 301. Two shapes reach it:
  #
  # The query form: PR #204 published /genres?filter=location before the path
  # grammar was routed, and /categories?filter=subject is the same query-string
  # shape on the new base. Collapsing it leaves one canonical shape and stops a crawler minting
  # query-string variants of a page this branch makes more crawlable. (The
  # /genres family itself is redirected by routes.rb before it gets here.)
  #
  # Non-canonical path forms: BrowsePath never emits /page/1, nor a path for the
  # default sort or type, so /categories/page/1 and /categories/sorted-by/book_count
  # are crawler-constructed duplicates of their own base. Every other paginated
  # family normalizes this with a literal `page/1` redirect route, but browse has
  # a dozen paginated shapes to their one, so comparing the request path with the
  # canonical target here beats a route entry per shape -- and it cannot be
  # forgotten when a shape is added.
  #
  # request.query_parameters, NOT params, for the query half: on a routed path
  # such as /categories/settings the same values arrive as PATH parameters, and
  # reading params for that test would redirect every routed request to itself
  # forever. The path half needs no such care: it compares the finished target
  # with request.path. A canonical request's target always equals its own path,
  # so it is never redirected -- which is what keeps this from looping.
  #
  # Declared above cache_for_index_page so a 301 is not decorated with 6-hour
  # public edge-cache headers.
  def redirect_to_canonical_form
    target = Books::BrowsePath.call(
      axis: action_name.to_sym,
      type: params[:filter],
      sort: params[:sort],
      page: params[:page]
    )
    return if request.query_parameters.slice(*QUERY_FORM_KEYS).empty? && target == request.path

    redirect_to target, status: :moved_permanently
  end

  def find_ranking_configuration
    @ranking_configuration = Books::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound if @ranking_configuration.nil?
  end

  def page_number
    params[:page].to_s.to_i
  end
end

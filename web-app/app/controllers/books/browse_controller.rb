class Books::BrowseController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :redirect_to_canonical_form
  before_action :cache_for_index_page
  before_action :find_ranking_configuration

  TITLES = {
    "genre" => "Book Genres",
    "location" => "Book Settings",
    "subject" => "Book Subjects"
  }.freeze

  QUERY_FORM_KEYS = %w[filter sort page].freeze

  def genres
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
    @canonical_path = Books::BrowsePath.call(axis: :genres, type: @type, page: page_number)

    @pagy, @records = pagy_path(
      Books::BrowseQuery.categories(ranking_configuration: @ranking_configuration, type: @type, sort: @sort),
      limit: 120
    )
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

  # Two non-canonical shapes fold into the path form here.
  #
  # The query form: PR #204 published /genres?filter=location before the legacy
  # path grammar was routed. Collapsing it leaves one canonical shape and stops a
  # crawler minting query-string variants of a page this branch makes more
  # crawlable.
  #
  # Page one: BrowsePath never emits /page/1, so every .../page/1 URL is a
  # crawler-constructed duplicate of its own base. Every other paginated family
  # normalizes this with a literal `page/1` redirect route, but browse has EIGHT
  # paginated shapes to their one, so one guard here beats eight route entries --
  # and it cannot be forgotten when a shape is added.
  #
  # request.query_parameters, NOT params, for the query half: on a routed path
  # such as /genres/filtered-by/location the same values arrive as PATH
  # parameters, and reading params would redirect every routed request to itself
  # forever. Page one is the deliberate exception -- it is read from params
  # precisely because it arrives as a path segment, and BrowsePath drops it, so
  # the target always differs from the request.
  #
  # Declared above cache_for_index_page so a 301 is not decorated with 6-hour
  # public edge-cache headers.
  def redirect_to_canonical_form
    return if request.query_parameters.slice(*QUERY_FORM_KEYS).empty? && page_number != 1

    redirect_to Books::BrowsePath.call(
      axis: action_name.to_sym,
      type: params[:filter],
      sort: params[:sort],
      page: params[:page]
    ), status: :moved_permanently
  end

  def find_ranking_configuration
    @ranking_configuration = Books::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound if @ranking_configuration.nil?
  end

  def page_number
    params[:page].to_s.to_i
  end
end

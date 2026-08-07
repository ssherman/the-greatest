class Books::BrowseController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :collapse_query_form
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
    @indexable = true
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
    @indexable = true
    @page_title = "Book Origins"
    @canonical_path = Books::BrowsePath.call(axis: :countries, page: page_number)

    @pagy, @records = pagy_path(
      Books::BrowseQuery.countries(ranking_configuration: @ranking_configuration, sort: @sort),
      limit: 120
    )
  end

  private

  # PR #204 published /genres?filter=location before the legacy path grammar was
  # routed. Collapsing it leaves one canonical shape and stops a crawler minting
  # query-string variants of a page this branch makes more crawlable.
  #
  # request.query_parameters, NOT params: on a routed path such as
  # /genres/filtered-by/location the same values arrive as PATH parameters, and
  # reading params would redirect every routed request to itself forever.
  def collapse_query_form
    return if request.query_parameters.slice(*QUERY_FORM_KEYS).empty?

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
    params[:page].to_i
  end
end

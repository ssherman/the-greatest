class Books::RankedItemsController < RankedItemsController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type, if: -> { @ranking_configuration.present? }
  before_action :find_collection
  before_action :cache_for_index_page, only: [:index]

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def index
    filters = Books::FilterParams.call(params)

    @categories = filters.categories
    @countries = filters.countries
    @year_start = filters.year_start
    @year_end = filters.year_end
    @filtered = @categories.any? || @countries.any? || @year_start.present? || @year_end.present?

    @show_hero = !@filtered && params[:page].blank? && params[:ranking_configuration_id].blank? && @collection.nil?

    @page_title = Books::FilterTitle.call(
      categories: @categories,
      countries: @countries,
      year_start: @year_start,
      year_end: @year_end,
      collection: @collection
    )
    # An /rc/ URL is noindex per the books public-UI spec's D4, so it gets no
    # canonical at all: emitting one that carries /rc/ would break D4, and one
    # pointing away would pair noindex with a canonical whose noindex can
    # propagate to the real page.
    if params[:ranking_configuration_id].blank?
      @canonical_path = Books::FilterPath.call(
        categories: @categories,
        countries: @countries,
        year_start: @year_start,
        year_end: @year_end,
        page: params[:page],
        collection: @collection
      )
    end

    @pagy, @ranked_books = pagy_path(
      Books::RankedBooksQuery.call(
        ranking_configuration: @ranking_configuration,
        categories: @categories,
        countries: @countries,
        year_start: @year_start,
        year_end: @year_end,
        collection: @collection
      ),
      limit: 100
    )

    @indexable = Books::FilterPath.indexable?(categories: @categories, countries: @countries) &&
      (!@filtered || @ranked_books.any?)
  end

  private

  # request.path_parameters, not params: params also picks up the query
  # string, and on a non-collection route (e.g. plain "/") there is no
  # :collection path segment, so params[:collection] would fall through to
  # ?collection=africa and let a query string reach the exact soft-duplicate
  # URL space the route's Regexp.union constraint exists to prevent.
  # path_parameters only contains what a route that passed the regex
  # populated.
  #
  # The route regex already restricts :collection to known slugs; this is the
  # defensive half, and the only thing standing between a future loosened
  # constraint and a 500.
  def find_collection
    slug = request.path_parameters[:collection]
    return if slug.blank?

    @collection = Collections::Registry.find(:books, slug)
    raise ActiveRecord::RecordNotFound if @collection.nil?
  end
end

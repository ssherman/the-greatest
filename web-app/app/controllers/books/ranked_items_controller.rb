class Books::RankedItemsController < RankedItemsController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type, if: -> { @ranking_configuration.present? }
  before_action :cache_for_index_page, only: [:index]

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def index
    filters = Books::FilterParams.call(params)

    @categories = filters.categories
    @countries = filters.countries
    @filtered = @categories.any? || @countries.any? || filters.year_start.present? || filters.year_end.present?

    @show_hero = !@filtered && params[:page].blank? && params[:ranking_configuration_id].blank?

    @page_title = Books::FilterTitle.call(
      categories: @categories,
      countries: @countries,
      year_start: filters.year_start,
      year_end: filters.year_end
    )
    # An /rc/ URL is noindex per the books public-UI spec's D4, so it gets no
    # canonical at all: emitting one that carries /rc/ would break D4, and one
    # pointing away would pair noindex with a canonical whose noindex can
    # propagate to the real page.
    if params[:ranking_configuration_id].blank?
      @canonical_path = Books::FilterPath.call(
        categories: @categories,
        countries: @countries,
        year_start: filters.year_start,
        year_end: filters.year_end,
        page: params[:page]
      )
    end

    @pagy, @ranked_books = pagy_path(
      Books::RankedBooksQuery.call(
        ranking_configuration: @ranking_configuration,
        categories: @categories,
        countries: @countries,
        year_start: filters.year_start,
        year_end: filters.year_end
      ),
      limit: 100
    )

    @indexable = !@filtered || @ranked_books.any?
  end
end

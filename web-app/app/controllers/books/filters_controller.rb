class Books::FiltersController < ApplicationController
  include Cacheable

  layout "books/application"

  # Subject and setting are long tails reached through search, so their pane
  # shows only the popular head; genre and audience are short closed lists.
  POPULAR_LIMIT = 25
  POPULAR_LIMIT_TYPES = %w[subject location].freeze

  before_action :prevent_caching
  before_action :find_ranking_configuration
  before_action :find_collection

  def show
    filters = resolved_filters

    redirect_to Books::FilterPath.call(
      categories: filters.categories,
      countries: filters.countries,
      year_start: filters.year_start,
      year_end: filters.year_end,
      ranking_configuration: @ranking_configuration,
      collection: @collection
    ), status: :see_other
  end

  # One lazily loaded page per category type. A missing type means genre: pages
  # served from the 6-hour edge-cached front page during a deploy still call
  # this without one.
  def categories
    type = params[:type].presence || "genre"
    raise ActiveRecord::RecordNotFound unless Books::FilterFacetsQuery::TYPES.include?(type)

    filters = resolved_filters
    rc = ranking_configuration_or_default

    if params[:q].present?
      rows = Books::FilterCategorySearchQuery.call(query: params[:q], type: type, **facet_args(filters, rc))
      render partial: "books/filters/results", locals: {type: type, rows: rows}, layout: false
    else
      limit = POPULAR_LIMIT_TYPES.include?(type) ? POPULAR_LIMIT : nil
      render Books::FilterPaneComponent.new(
        type: type,
        rows: Books::FilterFacetsQuery.categories(type: type, limit: limit, **facet_args(filters, rc)),
        results_src: limit ? categories_pane_path(type) : nil
      ), layout: false
    end
  end

  # Origin filters client-side, so the whole facet ships and there is no q branch.
  def countries
    filters = resolved_filters
    rc = ranking_configuration_or_default

    render Books::FilterPaneComponent.new(
      type: "country",
      rows: Books::FilterFacetsQuery.countries(**facet_args(filters, rc))
    ), layout: false
  end

  # Backs the panel's live "Show N books" button. Counts the same set the
  # results page lists (RankedBooksQuery), so the button never promises a
  # number the page then contradicts.
  def count
    filters = resolved_filters
    rc = ranking_configuration_or_default

    # except(:includes)/reorder(nil): the query eager-loads and orders for
    # display, which a COUNT neither needs nor wants.
    total = Books::RankedBooksQuery.call(**facet_args(filters, rc)).except(:includes).reorder(nil).count

    render json: {count: total}
  end

  private

  def ranking_configuration_or_default
    rc = @ranking_configuration || Books::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound if rc.nil?

    rc
  end

  def facet_args(filters, rc)
    {
      ranking_configuration: rc,
      categories: filters.categories,
      countries: filters.countries,
      year_start: filters.year_start,
      year_end: filters.year_end,
      collection: @collection
    }
  end

  # The URL a subject/setting pane searches against: its own type plus the
  # applied filters, never q (the client appends that).
  def categories_pane_path(type)
    permitted = params.permit(:year_start, :year_end, :ranking_configuration_id, :collection, category_slugs: [], country_slugs: [])
    books_filters_categories_path(permitted.to_h.merge(type: type))
  end

  def resolved_filters
    Books::FilterParams.call(
      ActionController::Parameters.new(
        category_id: Array(params[:category_slugs]).join(","),
        country_id: Array(params[:country_slugs]).join(","),
        published_start: params[:year_start],
        published_end: params[:year_end]
      )
    )
  end

  def find_ranking_configuration
    return if params[:ranking_configuration_id].blank?

    @ranking_configuration = Books::RankingConfiguration.find(params[:ranking_configuration_id])
    gate_ranking_configuration!(@ranking_configuration)
  end

  # params, not request.path_parameters: this endpoint is reached as
  # GET /filters?collection=africa&... from the filter modal's form -- the
  # query string is its only source, since /filters is not a collection route.
  def find_collection
    return if params[:collection].blank?

    @collection = Collections::Registry.find(:books, params[:collection])
    raise ActiveRecord::RecordNotFound if @collection.nil?
  end
end

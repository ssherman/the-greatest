class Books::FiltersController < ApplicationController
  include Cacheable

  layout "books/application"

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

  def categories
    render_pane(:category)
  end

  def countries
    render_pane(:country)
  end

  private

  def render_pane(axis)
    filters = resolved_filters
    rc = @ranking_configuration || Books::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound if rc.nil?

    if params[:q].present?
      render_pane_results(axis)
    else
      render_pane_body(axis, filters, rc)
    end
  end

  def render_pane_results(axis)
    # No types: -- the Category axis is defined as genres, subjects AND
    # settings. Scoping it here would break the pane's own placeholder and two
    # Playwright tests.
    rows = if axis == :category
      CategorySearchQuery.call(params[:q], scope: ::Books::Category)
    else
      ::Books::CountrySearchQuery.call(params[:q])
    end

    render partial: "books/filters/results",
      locals: {axis: axis, rows: rows, results_src: pane_path(axis)},
      layout: false
  end

  def render_pane_body(axis, filters, rc)
    facet_rows = if axis == :category
      Books::FilterFacetsQuery.genres(**facet_args(filters, rc))
    else
      Books::FilterFacetsQuery.countries(**facet_args(filters, rc))
    end

    render Books::FilterPaneComponent.new(
      axis: axis,
      facet_rows: facet_rows,
      results_src: pane_path(axis)
    ), layout: false
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

  def pane_path(axis)
    (axis == :category) ? books_filters_categories_path : books_filters_countries_path
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

class Books::FiltersController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :prevent_caching
  before_action :find_ranking_configuration

  def show
    filters = resolved_filters

    redirect_to Books::FilterPath.call(
      categories: filters.categories,
      countries: filters.countries,
      year_start: filters.year_start,
      year_end: filters.year_end,
      ranking_configuration: @ranking_configuration
    ), status: :see_other
  end

  private

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
end

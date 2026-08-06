class Books::BrowseController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :cache_for_index_page
  before_action :find_ranking_configuration

  TITLES = {
    "genre" => "Book Genres",
    "location" => "Book Settings",
    "subject" => "Book Subjects"
  }.freeze

  def genres
    @type = Books::BrowseQuery.normalized_type(params[:filter])
    @sort = Books::BrowseQuery.normalized_sort(params[:sort])
    @indexable = true
    @page_title = TITLES.fetch(@type)
    filter = (@type == Books::BrowseQuery::TYPES.first) ? {} : {filter: @type}
    @canonical_path = paged? ? books_genres_page_path(page: page_number, **filter) : books_genres_path(**filter)

    @pagy, @records = pagy_path(
      Books::BrowseQuery.categories(ranking_configuration: @ranking_configuration, type: @type, sort: @sort),
      limit: 120
    )
  end

  def countries
    @sort = Books::BrowseQuery.normalized_sort(params[:sort])
    @indexable = true
    @page_title = "Book Origins"
    @canonical_path = paged? ? books_countries_page_path(page: page_number) : books_countries_path

    @pagy, @records = pagy_path(
      Books::BrowseQuery.countries(ranking_configuration: @ranking_configuration, sort: @sort),
      limit: 120
    )
  end

  private

  def find_ranking_configuration
    @ranking_configuration = Books::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound if @ranking_configuration.nil?
  end

  def page_number
    params[:page].to_i
  end

  def paged?
    page_number > 1
  end
end

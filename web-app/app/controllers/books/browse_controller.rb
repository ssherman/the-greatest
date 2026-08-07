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

  def find_ranking_configuration
    @ranking_configuration = Books::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound if @ranking_configuration.nil?
  end

  def page_number
    params[:page].to_i
  end
end

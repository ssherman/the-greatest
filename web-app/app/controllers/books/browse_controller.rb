class Books::BrowseController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :cache_for_index_page

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
    @canonical_path = (@type == Books::BrowseQuery::TYPES.first) ? books_genres_path : books_genres_path(filter: @type)

    @pagy, @records = pagy_path(Books::BrowseQuery.categories(type: @type, sort: @sort), limit: 120)
  end
end

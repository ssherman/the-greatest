class Books::SearchesController < ApplicationController
  include Cacheable

  layout "books/application"

  # A results page is keyed on visitor-supplied text: indexing it is unbounded
  # and caching it would hand one visitor's results to the next. `@indexable`
  # is left unset, which is what books_robots_content reads as noindex.
  before_action :prevent_caching

  def index
    @query = params[:q]
    @books = Books::BookSearchQuery.call(@query)
  end
end

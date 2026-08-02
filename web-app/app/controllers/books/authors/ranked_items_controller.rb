class Books::Authors::RankedItemsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :cache_for_index_page, only: [:index]

  def index
    @ranking_configuration = Books::Authors::RankingConfiguration.default_primary

    if @ranking_configuration.nil?
      @indexable = false
      reject_paged_request!
      @ranked_authors = []
      @pagy = nil
      @top_books = {}
      return
    end

    @pagy, @ranked_authors = pagy_path(
      Books::RankedAuthorsQuery.call(ranking_configuration: @ranking_configuration),
      limit: 100
    )

    @top_books = Books::TopBooksForAuthorsQuery.call(
      author_ids: @ranked_authors.map(&:item_id),
      ranking_configuration: Books::RankingConfiguration.default_primary
    )
    @indexable = @ranked_authors.any?
  end
end

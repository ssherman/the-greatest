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
    @indexable = true
    @show_hero = params[:page].blank? && params[:ranking_configuration_id].blank?

    @pagy, @ranked_books = pagy_path(
      Books::RankedBooksQuery.call(ranking_configuration: @ranking_configuration),
      limit: 100
    )
  end
end

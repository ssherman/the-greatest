class Games::RankedItemsController < RankedItemsController
  include Pagy::Method
  include Cacheable

  layout "games/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type
  before_action :parse_year_filter
  before_action :cache_for_index_page, only: [:index]

  def self.ranking_configuration_class
    Games::RankingConfiguration
  end

  def index
    games_query = @ranking_configuration.ranked_items
      .joins("JOIN games_games ON ranked_items.item_id = games_games.id AND ranked_items.item_type = 'Games::Game'")
      .includes(item: [:categories, :primary_image, {game_companies: :company}])
      .where(item_type: "Games::Game")

    if @year_filter
      filter_service = Services::RankedItemsFilterService.new(games_query, table_name: "games_games")
      games_query = filter_service.apply_year_filter(@year_filter)
    end

    games_query = games_query.order(:rank)

    @pagy, @games = pagy(games_query, limit: 100)
  end

  private

  def parse_year_filter
    return unless params[:year].present?

    @year_filter = ::Filters::YearFilter.parse(params[:year], mode: params[:year_mode])
  rescue ArgumentError
    raise ActionController::RoutingError, "Not Found"
  end
end

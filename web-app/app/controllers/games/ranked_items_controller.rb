class Games::RankedItemsController < RankedItemsController
  include Pagy::Method
  include Cacheable

  layout "games/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type, if: -> { @ranking_configuration.present? }
  before_action :parse_year_filter, if: -> { @ranking_configuration.present? }
  before_action :cache_for_index_page, only: [:index]

  def self.ranking_configuration_class
    Games::RankingConfiguration
  end

  def index
    return render "games/ranked_items/coming_soon" unless @ranking_configuration

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

  def find_ranking_configuration
    @ranking_configuration = if params[:ranking_configuration_id].present?
      RankingConfiguration.find(params[:ranking_configuration_id])
    else
      self.class.ranking_configuration_class.default_primary
    end
  end

  def parse_year_filter
    return unless params[:year].present?

    @year_filter = ::Filters::YearFilter.parse(params[:year], mode: params[:year_mode])
  rescue ArgumentError
    raise ActionController::RoutingError, "Not Found"
  end
end

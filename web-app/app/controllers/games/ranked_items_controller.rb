class Games::RankedItemsController < RankedItemsController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination
  include CsvExportable

  layout "games/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type, if: -> { @ranking_configuration.present? }
  before_action :parse_year_filter, if: -> { @ranking_configuration.present? }
  before_action :cache_for_index_page, only: [:index]

  def self.ranking_configuration_class
    Games::RankingConfiguration
  end

  def index
    unless @ranking_configuration
      reject_paged_request!
      return render "games/ranked_items/coming_soon"
    end

    @show_hero = !params[:year].present? && !params[:page].present? && !params[:ranking_configuration_id].present?

    games_query = @ranking_configuration.ranked_items
      .joins("JOIN games_games ON ranked_items.item_id = games_games.id AND ranked_items.item_type = 'Games::Game'")
      .includes(item: [:categories, :primary_image, {game_companies: :company}])
      .where(item_type: "Games::Game")

    if @year_filter
      filter_service = Services::RankedItemsFilterService.new(games_query, table_name: "games_games")
      games_query = filter_service.apply_year_filter(@year_filter)
    end

    games_query = games_query.order(:rank)

    @pagy, @games = pagy_path(games_query, limit: 100)
    @csv_export_path = csv_export_path
  end

  # GET (/rc/:ranking_configuration_id)/video-games/export.csv?year=&year_mode=
  def export
    raise ActiveRecord::RecordNotFound if @ranking_configuration.nil? # no primary yet: index shows "coming soon"
    return serve_prebuilt_or_prepare(@ranking_configuration) if @year_filter.nil? && current_user.member?

    send_year_filtered_export(@ranking_configuration, year_filter: @year_filter)
  end

  private

  def csv_export_path
    video_games_export_path(
      **{ranking_configuration_id: params[:ranking_configuration_id].presence,
         year: params[:year].presence, year_mode: params[:year_mode].presence}.compact,
      format: :csv
    )
  end

  # The preparing page's back link: this configuration's games page.
  def csv_export_back_path
    video_games_path(ranking_configuration_id: params[:ranking_configuration_id].presence)
  end

  def find_ranking_configuration
    @ranking_configuration = if params[:ranking_configuration_id].present?
      RankingConfiguration.find(params[:ranking_configuration_id])
    else
      self.class.ranking_configuration_class.default_primary
    end

    gate_ranking_configuration!(@ranking_configuration)
  end

  def parse_year_filter
    return unless params[:year].present?

    @year_filter = ::Filters::YearFilter.parse(params[:year], mode: params[:year_mode])
  rescue ArgumentError
    raise ActionController::RoutingError, "Not Found"
  end
end

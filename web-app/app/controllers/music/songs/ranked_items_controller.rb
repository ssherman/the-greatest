class Music::Songs::RankedItemsController < Music::RankedItemsController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination
  include CsvExportable

  layout "music/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type
  before_action :parse_year_filter
  before_action :cache_for_index_page, only: [:index]

  def self.ranking_configuration_class
    Music::Songs::RankingConfiguration
  end

  def index
    songs_query = @ranking_configuration.ranked_items
      .joins("JOIN music_songs ON ranked_items.item_id = music_songs.id AND ranked_items.item_type = 'Music::Song'")
      .includes(item: [:artists, :categories])
      .where(item_type: "Music::Song")

    if @year_filter
      filter_service = Services::RankedItemsFilterService.new(songs_query, table_name: "music_songs")
      songs_query = filter_service.apply_year_filter(@year_filter)
    end

    songs_query = songs_query.order(:rank)

    @pagy, @songs = pagy_path(songs_query, limit: 100)
    @csv_export_path = csv_export_path
  end

  # GET (/rc/:ranking_configuration_id)/songs/export.csv?year=&year_mode=
  def export
    return serve_prebuilt_or_prepare(@ranking_configuration) if @year_filter.nil? && current_user.member?

    entry = CsvExports::Registry.for_config(@ranking_configuration)
    relation = entry.relation.call(@ranking_configuration)
    if @year_filter
      relation = Services::RankedItemsFilterService.new(relation, table_name: "music_songs").apply_year_filter(@year_filter)
    end
    send_on_demand_ranked_items(relation, row_class: entry.row_class,
      filename: CsvExports::Registry.filename_for(@ranking_configuration))
  end

  private

  def csv_export_path
    songs_export_path(
      **{ranking_configuration_id: params[:ranking_configuration_id].presence,
         year: params[:year].presence, year_mode: params[:year_mode].presence}.compact,
      format: :csv
    )
  end

  # The preparing page's back link: this configuration's songs page.
  def csv_export_back_path
    songs_path(ranking_configuration_id: params[:ranking_configuration_id].presence)
  end
end

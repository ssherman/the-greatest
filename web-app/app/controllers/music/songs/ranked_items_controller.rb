class Music::Songs::RankedItemsController < Music::RankedItemsController
  include Pagy::Method
  include Cacheable

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

    @pagy, @songs = pagy(songs_query, limit: 100)
  end
end

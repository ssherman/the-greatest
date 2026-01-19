class Music::Albums::RankedItemsController < Music::RankedItemsController
  include Pagy::Method
  include Cacheable

  layout "music/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type
  before_action :parse_year_filter
  before_action :cache_for_index_page, only: [:index]

  def self.ranking_configuration_class
    Music::Albums::RankingConfiguration
  end

  def index
    albums_query = @ranking_configuration.ranked_items
      .joins("JOIN music_albums ON ranked_items.item_id = music_albums.id AND ranked_items.item_type = 'Music::Album'")
      .includes(item: [:artists, :categories, :primary_image])
      .where(item_type: "Music::Album")

    if @year_filter
      filter_service = Services::RankedItemsFilterService.new(albums_query, table_name: "music_albums")
      albums_query = filter_service.apply_year_filter(@year_filter)
    end

    albums_query = albums_query.order(:rank)

    @pagy, @albums = pagy(albums_query, limit: 100)
  end
end

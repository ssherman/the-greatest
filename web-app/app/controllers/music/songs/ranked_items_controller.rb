class Music::Songs::RankedItemsController < Music::RankedItemsController
  include Pagy::Backend
  include Cacheable

  layout "music/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type
  before_action :cache_for_index_page, only: [:index]

  def self.ranking_configuration_class
    Music::Songs::RankingConfiguration
  end

  def index
    songs_query = @ranking_configuration.ranked_items
      .joins("JOIN music_songs ON ranked_items.item_id = music_songs.id AND ranked_items.item_type = 'Music::Song'")
      .includes(item: [:artists, :categories])
      .where(item_type: "Music::Song")
      .order(:rank)

    @pagy, @songs = pagy(songs_query, limit: 100)
  end
end

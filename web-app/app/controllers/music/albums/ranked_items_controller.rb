class Music::Albums::RankedItemsController < Music::RankedItemsController
  include Pagy::Backend

  layout "music/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type

  def self.ranking_configuration_class
    Music::Albums::RankingConfiguration
  end

  def index
    albums_query = @ranking_configuration.ranked_items
      .joins("JOIN music_albums ON ranked_items.item_id = music_albums.id AND ranked_items.item_type = 'Music::Album'")
      .includes(item: [:artists, :categories, :primary_image])
      .where(item_type: "Music::Album")
      .order(:rank)

    @pagy, @albums = pagy(albums_query, limit: 25)
  end
end

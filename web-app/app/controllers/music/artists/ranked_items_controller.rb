class Music::Artists::RankedItemsController < ApplicationController
  include Pagy::Backend
  include Cacheable

  layout "music/application"

  before_action :cache_for_index_page, only: [:index]

  def index
    @ranking_configuration = Music::Artists::RankingConfiguration.default_primary

    unless @ranking_configuration
      @artists = []
      @pagy = nil
      return
    end

    artists_query = @ranking_configuration.ranked_items
      .joins("JOIN music_artists ON ranked_items.item_id = music_artists.id AND ranked_items.item_type = 'Music::Artist'")
      .includes(item: [:categories, :primary_image])
      .where(item_type: "Music::Artist")
      .order(:rank)

    @pagy, @artists = pagy(artists_query, limit: 100)
  end
end

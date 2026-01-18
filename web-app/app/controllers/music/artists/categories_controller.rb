class Music::Artists::CategoriesController < ApplicationController
  include Pagy::Method
  include Cacheable

  layout "music/application"

  before_action :load_ranking_configuration
  before_action :cache_for_index_page, only: [:show]

  def self.ranking_configuration_class
    Music::Artists::RankingConfiguration
  end

  def show
    @category = Music::Category.active.friendly.find(params[:id])

    artists_query = build_ranked_artists_query
    @pagy, @artists = pagy(artists_query, limit: 100)
  end

  private

  def build_ranked_artists_query
    return Music::Artist.none unless @ranking_configuration

    RankedItem
      .joins("JOIN category_items ON category_items.item_id = ranked_items.item_id AND category_items.item_type = 'Music::Artist'")
      .joins("JOIN music_artists ON music_artists.id = ranked_items.item_id")
      .where(
        item_type: "Music::Artist",
        ranking_configuration_id: @ranking_configuration.id,
        category_items: {category_id: @category.id}
      )
      .includes(item: [:categories, :primary_image])
      .order(:rank)
  end
end

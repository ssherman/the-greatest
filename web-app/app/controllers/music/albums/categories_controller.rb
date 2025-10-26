class Music::Albums::CategoriesController < ApplicationController
  include Pagy::Backend

  layout "music/application"

  before_action :load_ranking_configuration

  def self.ranking_configuration_class
    Music::Albums::RankingConfiguration
  end

  def show
    @category = Music::Category.active.friendly.find(params[:id])

    albums_query = build_ranked_albums_query
    @pagy, @albums = pagy(albums_query, limit: 100)
  end

  private

  def build_ranked_albums_query
    return Music::Album.none unless @ranking_configuration

    RankedItem
      .joins("JOIN category_items ON category_items.item_id = ranked_items.item_id AND category_items.item_type = 'Music::Album'")
      .joins("JOIN music_albums ON music_albums.id = ranked_items.item_id")
      .where(
        item_type: "Music::Album",
        ranking_configuration_id: @ranking_configuration.id,
        category_items: {category_id: @category.id}
      )
      .includes(item: [:artists, :categories, :primary_image])
      .order(:rank)
  end
end

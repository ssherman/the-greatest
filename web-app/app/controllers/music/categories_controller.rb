class Music::CategoriesController < ApplicationController
  include Cacheable

  layout "music/application"

  before_action :cache_for_index_page, only: [:show]

  def show
    @category = Music::Category.active.friendly.find(params[:id])

    @artist_rc = Music::Artists::RankingConfiguration.default_primary
    @album_rc = Music::Albums::RankingConfiguration.default_primary

    @artists = build_ranked_artists_query.limit(10)
    @albums = build_ranked_albums_query.limit(10)
  end

  private

  def build_ranked_artists_query
    return Music::Artist.none unless @artist_rc

    RankedItem
      .joins("JOIN category_items ON category_items.item_id = ranked_items.item_id AND category_items.item_type = 'Music::Artist'")
      .joins("JOIN music_artists ON music_artists.id = ranked_items.item_id")
      .where(
        item_type: "Music::Artist",
        ranking_configuration_id: @artist_rc.id,
        category_items: {category_id: @category.id}
      )
      .includes(item: [:categories, :primary_image])
      .order(:rank)
  end

  def build_ranked_albums_query
    return Music::Album.none unless @album_rc

    RankedItem
      .joins("JOIN category_items ON category_items.item_id = ranked_items.item_id AND category_items.item_type = 'Music::Album'")
      .joins("JOIN music_albums ON music_albums.id = ranked_items.item_id")
      .where(
        item_type: "Music::Album",
        ranking_configuration_id: @album_rc.id,
        category_items: {category_id: @category.id}
      )
      .includes(item: [:artists, :categories, :primary_image])
      .order(:rank)
  end
end

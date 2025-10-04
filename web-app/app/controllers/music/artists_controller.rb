class Music::ArtistsController < ApplicationController
  layout "music/application"

  def show
    @artist = Music::Artist.includes(:categories, :primary_image)
      .friendly
      .find(params[:id])

    @categories_by_type = @artist.categories.group_by(&:category_type)

    @album_rc = if params[:ranking_configuration_id].present?
      RankingConfiguration.find(params[:ranking_configuration_id])
    else
      Music::Albums::RankingConfiguration.default_primary
    end

    @greatest_albums = if @album_rc
      @artist.albums
        .joins("JOIN ranked_items ON ranked_items.item_id = music_albums.id AND ranked_items.item_type = 'Music::Album'")
        .where(ranked_items: {ranking_configuration_id: @album_rc.id})
        .includes(:artists, :primary_image, :categories)
        .order("ranked_items.rank ASC")
        .limit(10)
    else
      []
    end

    @song_rc = Music::Songs::RankingConfiguration.default_primary
    @greatest_songs = if @song_rc
      @artist.songs
        .joins("JOIN ranked_items ON ranked_items.item_id = music_songs.id AND ranked_items.item_type = 'Music::Song'")
        .where(ranked_items: {ranking_configuration_id: @song_rc.id})
        .includes(:artists)
        .order("ranked_items.rank ASC")
        .limit(10)
    else
      []
    end

    @all_albums = @artist.albums
      .includes(:artists, :primary_image)
      .order(release_year: :desc)
  end
end

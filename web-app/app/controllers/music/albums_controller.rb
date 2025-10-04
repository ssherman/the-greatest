class Music::AlbumsController < ApplicationController
  layout "music/application"

  def show
    @album = Music::Album.includes(:artists, :categories, :primary_image, :lists)
      .friendly
      .find(params[:id])

    @categories_by_type = @album.categories.group_by(&:category_type)
    @artist_names = @album.artists.map(&:name).join(", ")
    @genre_text = @categories_by_type["genre"]&.first&.name || "music"

    @ranking_configuration = if params[:ranking_configuration_id].present?
      RankingConfiguration.find(params[:ranking_configuration_id])
    else
      Music::Albums::RankingConfiguration.default_primary
    end

    @ranked_item = @ranking_configuration&.ranked_items&.find_by(item: @album)
  end
end

class Music::SongsController < ApplicationController
  layout "music/application"

  def show
    @song = Music::Song.includes(:artists, :categories)
      .friendly
      .find(params[:id])

    @categories_by_type = @song.categories.group_by(&:category_type)
    @artist_names = @song.artists.map(&:name).join(", ")

    @ranking_configuration = if params[:ranking_configuration_id].present?
      RankingConfiguration.find(params[:ranking_configuration_id])
    else
      Music::Songs::RankingConfiguration.default_primary
    end

    @ranked_item = @ranking_configuration&.ranked_items&.find_by(item: @song)

    @albums = @song.albums
      .distinct
      .includes(:artists, :primary_image)
      .order(release_year: :desc)
  end
end

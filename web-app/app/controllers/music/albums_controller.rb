class Music::AlbumsController < ApplicationController
  layout "music/application"

  before_action :load_ranking_configuration, only: [:show]

  def self.ranking_configuration_class
    Music::Albums::RankingConfiguration
  end

  def show
    @album = Music::Album
      .includes(:artists, :categories, :lists)
      .with_primary_image_for_display
      .friendly
      .find(params[:id])

    @categories_by_type = @album.categories.group_by(&:category_type)
    @artist_names = @album.artists.map(&:name).join(", ")
    @genre_text = @categories_by_type["genre"]&.first&.name || "music"

    @ranked_item = @ranking_configuration&.ranked_items&.find_by(item: @album)
  end
end

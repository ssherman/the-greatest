class Music::SongsController < ApplicationController
  layout "music/application"

  before_action :load_ranking_configuration, only: [:show]

  def self.ranking_configuration_class
    Music::Songs::RankingConfiguration
  end

  def show
    @song = Music::Song.includes(:artists, :categories)
      .friendly
      .find(params[:id])

    @categories_by_type = @song.categories.group_by(&:category_type)
    @artist_names = @song.artists.map(&:name).join(", ")

    @ranked_item = @ranking_configuration&.ranked_items&.find_by(item: @song)

    @albums = @song.albums
      .distinct
      .includes(:artists)
      .with_primary_image_for_display
      .order(release_year: :desc)

    @lists = @song.lists.includes(:list_items).to_a
  end
end

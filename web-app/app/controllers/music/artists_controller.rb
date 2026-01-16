class Music::ArtistsController < ApplicationController
  include Cacheable

  layout "music/application"

  before_action :load_album_ranking_configuration, only: [:show]
  before_action :load_song_ranking_configuration, only: [:show]
  before_action :cache_for_show_page, only: [:show]

  def show
    @artist = Music::Artist
      .includes(:categories)
      .with_primary_image_for_display
      .friendly.find(params[:id])

    @categories_by_type = @artist.categories.group_by(&:category_type)

    @greatest_albums = if @album_rc
      @artist.albums
        .joins("JOIN ranked_items ON ranked_items.item_id = music_albums.id AND ranked_items.item_type = 'Music::Album'")
        .where(ranked_items: {ranking_configuration_id: @album_rc.id})
        .includes(:artists, :categories)
        .with_primary_image_for_display
        .order("ranked_items.rank ASC")
        .limit(10)
    else
      []
    end

    @greatest_songs = if @song_rc
      @artist.songs
        .joins("JOIN ranked_items ON ranked_items.item_id = music_songs.id AND ranked_items.item_type = 'Music::Song'")
        .where(ranked_items: {ranking_configuration_id: @song_rc.id})
        .includes(:artists)
        .order("ranked_items.rank ASC")
        .limit(10)
        .to_a
    else
      []
    end

    @all_albums = @artist.albums
      .includes(:artists)
      .with_primary_image_for_display
      .order(release_year: :desc)
  end

  private

  def load_album_ranking_configuration
    load_ranking_configuration(
      config_class: Music::Albums::RankingConfiguration,
      instance_var: :@album_rc
    )
  end

  def load_song_ranking_configuration
    # Always use default for songs, don't read from params
    @song_rc = Music::Songs::RankingConfiguration.default_primary
  end
end

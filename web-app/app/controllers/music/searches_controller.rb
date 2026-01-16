module Music
  class SearchesController < ApplicationController
    include Cacheable

    layout "music/application"

    before_action :prevent_caching

    def index
      @query = params[:q]

      if @query.blank?
        @artists = []
        @albums = []
        @songs = []
        @total_count = 0
        return
      end

      @artist_results = ::Search::Music::Search::ArtistGeneral.call(@query, size: 25)
      @album_results = ::Search::Music::Search::AlbumGeneral.call(@query, size: 25)
      @song_results = ::Search::Music::Search::SongGeneral.call(@query, size: 10)

      @artists = load_artists(@artist_results)
      @albums = load_albums(@album_results)
      @songs = load_songs(@song_results)

      @total_count = @artists.size + @albums.size + @songs.size
    end

    private

    def load_artists(results)
      return [] if results.empty?
      ids = results.map { |r| r[:id].to_i }.uniq
      records_by_id = Music::Artist.where(id: ids)
        .includes(:categories, :primary_image)
        .index_by(&:id)
      ids.map { |id| records_by_id[id] }.compact
    end

    def load_albums(results)
      return [] if results.empty?
      ids = results.map { |r| r[:id].to_i }.uniq
      records_by_id = Music::Album.where(id: ids)
        .includes(:artists, :categories, :primary_image)
        .index_by(&:id)
      ids.map { |id| records_by_id[id] }.compact
    end

    def load_songs(results)
      return [] if results.empty?
      ids = results.map { |r| r[:id].to_i }.uniq
      records_by_id = Music::Song.where(id: ids)
        .includes(:artists, :categories)
        .index_by(&:id)
      ids.map { |id| records_by_id[id] }.compact
    end
  end
end

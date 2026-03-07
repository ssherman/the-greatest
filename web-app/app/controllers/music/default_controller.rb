class Music::DefaultController < ApplicationController
  include Cacheable

  layout "music/application"

  before_action :cache_for_index_page, only: [:index, :rankings]

  def index
    @primary_album_rc = Music::Albums::RankingConfiguration.default_primary
    @primary_song_rc = Music::Songs::RankingConfiguration.default_primary

    if @primary_album_rc
      @featured_albums = @primary_album_rc.ranked_items
        .includes(item: [:artists, :primary_image])
        .where(item_type: "Music::Album")
        .order(:rank)
        .limit(6)
    end

    if @primary_song_rc
      @featured_songs = @primary_song_rc.ranked_items
        .includes(item: [:artists])
        .where(item_type: "Music::Song")
        .order(:rank)
        .limit(10)
    end
  end

  def rankings
    @album_rc = Music::Albums::RankingConfiguration.default_primary
    @song_rc = Music::Songs::RankingConfiguration.default_primary

    album_penalties = @album_rc&.penalties&.to_a || []
    song_penalties = @song_rc&.penalties&.to_a || []
    all_penalties = (album_penalties + song_penalties).uniq(&:name)

    @static_penalties = all_penalties.select(&:static?)
    @dynamic_penalties = all_penalties.select(&:dynamic?)

    @active_lists_count = (@album_rc&.ranked_lists&.count || 0) + (@song_rc&.ranked_lists&.count || 0)
    @ranked_items_count = (@album_rc&.ranked_items&.where&.not(rank: nil)&.count || 0) + (@song_rc&.ranked_items&.where&.not(rank: nil)&.count || 0)
    @median_list_count = List.median_list_count(type: "Music::Albums::List")
  end
end

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

  EXAMPLE_LIST_ID = 10_015

  def rankings
    result = Services::RankingConfiguration::ExplainerData.call(
      configurations: [
        Music::Albums::RankingConfiguration.default_primary,
        Music::Songs::RankingConfiguration.default_primary
      ],
      example_list_id: EXAMPLE_LIST_ID
    )

    raise ActiveRecord::RecordNotFound, result.errors.join(", ") unless result.success?

    @data = result.data
  end
end

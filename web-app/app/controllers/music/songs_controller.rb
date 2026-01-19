class Music::SongsController < ApplicationController
  include Cacheable

  layout "music/application"

  before_action :load_ranking_configuration, only: [:show]
  before_action :cache_for_show_page, only: [:show]

  def self.ranking_configuration_class
    Music::Songs::RankingConfiguration
  end

  def show
    @song = Music::Song.includes(
      :artists,
      :categories,
      albums: [:artists, {primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}}}],
      lists: :list_items
    )
      .friendly
      .find(params[:slug])

    @categories_by_type = @song.categories.group_by(&:category_type)
    @artist_names = @song.artists.map(&:name).join(", ")

    @ranked_item = @ranking_configuration&.ranked_items&.find_by(item: @song)

    @albums = @song.albums
      .distinct
      .order(release_year: :desc)

    @lists = @song.lists.to_a
  end
end

class Music::ListsController < ApplicationController
  include Cacheable

  layout "music/application"

  before_action :load_ranking_configurations, only: [:index]
  before_action :cache_for_index_page, only: [:index]

  def index
    @albums_ranked_lists = @albums_ranking_configuration.ranked_lists
      .joins(:list)
      .where(lists: {type: "Music::Albums::List"})
      .includes(list: :list_items)
      .order(weight: :desc)
      .limit(50)

    @songs_ranked_lists = @songs_ranking_configuration.ranked_lists
      .joins(:list)
      .where(lists: {type: "Music::Songs::List"})
      .includes(list: :list_items)
      .order(weight: :desc)
      .limit(50)
  end

  private

  def load_ranking_configurations
    @albums_ranking_configuration = Music::Albums::RankingConfiguration.default_primary
    @songs_ranking_configuration = Music::Songs::RankingConfiguration.default_primary
  end
end

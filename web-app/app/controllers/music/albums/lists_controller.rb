class Music::Albums::ListsController < ApplicationController
  include Pagy::Backend

  layout "music/application"

  before_action :load_ranking_configuration

  def self.ranking_configuration_class
    Music::Albums::RankingConfiguration
  end

  def index
    sort_order = (params[:sort] == "created_at") ? {"lists.created_at": :desc} : {weight: :desc}

    ranked_lists_query = @ranking_configuration.ranked_lists
      .joins(:list)
      .where(lists: {type: "Music::Albums::List"})
      .includes(list: :list_items)
      .order(sort_order)

    @pagy, @ranked_lists = pagy(ranked_lists_query, limit: 25)
  end

  def show
    @list = Music::Albums::List.with_albums_for_display.find(params[:id])
    @ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)
  end
end

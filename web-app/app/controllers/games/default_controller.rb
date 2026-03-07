class Games::DefaultController < ApplicationController
  include Cacheable

  layout "games/application"

  before_action :cache_for_index_page, only: [:rankings]

  def index
  end

  def rankings
    @ranking_configuration = Games::RankingConfiguration.default_primary

    penalties = @ranking_configuration&.penalties&.to_a || []

    @static_penalties = penalties.select(&:static?)
    @dynamic_penalties = penalties.select(&:dynamic?)

    @active_lists_count = @ranking_configuration&.ranked_lists&.count || 0
    @ranked_items_count = @ranking_configuration&.ranked_items&.where&.not(rank: nil)&.count || 0
    @median_list_count = List.median_list_count(type: "Games::List")
  end
end

class Games::ListsController < ApplicationController
  include Cacheable

  layout "games/application"

  before_action :load_ranking_configuration, only: [:index]
  before_action :cache_for_index_page, only: [:index]

  def index
    @ranked_lists = @ranking_configuration.ranked_lists
      .joins(:list)
      .where(lists: {type: "Games::List"})
      .includes(list: :list_items)
      .order(weight: :desc)
      .limit(50)
  end

  private

  def load_ranking_configuration
    @ranking_configuration = Games::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound unless @ranking_configuration
  end
end

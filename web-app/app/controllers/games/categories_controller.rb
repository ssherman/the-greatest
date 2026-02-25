class Games::CategoriesController < ApplicationController
  include Pagy::Method
  include Cacheable

  layout "games/application"

  before_action :load_ranking_configuration
  before_action :cache_for_index_page, only: [:show]

  def self.ranking_configuration_class
    Games::RankingConfiguration
  end

  def show
    @category = Games::Category.active.friendly.find(params[:id])

    games_query = build_ranked_games_query
    @pagy, @games = pagy(games_query, limit: 100)
  end

  private

  def build_ranked_games_query
    return Games::Game.none unless @ranking_configuration

    RankedItem
      .joins("JOIN category_items ON category_items.item_id = ranked_items.item_id AND category_items.item_type = 'Games::Game'")
      .joins("JOIN games_games ON games_games.id = ranked_items.item_id AND ranked_items.item_type = 'Games::Game'")
      .where(
        item_type: "Games::Game",
        ranking_configuration_id: @ranking_configuration.id,
        category_items: {category_id: @category.id}
      )
      .includes(item: [:categories, :primary_image, {game_companies: :company}])
      .order(:rank)
  end
end

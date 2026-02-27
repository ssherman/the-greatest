module Games
  class SearchesController < ApplicationController
    include Cacheable

    layout "games/application"

    before_action :prevent_caching

    def index
      @query = params[:q]

      if @query.blank?
        @games = []
        @total_count = 0
        return
      end

      results = ::Search::Games::Search::GameGeneral.call(@query, size: 50)

      @games = load_games(results)
      @total_count = @games.size
    end

    private

    def load_games(results)
      return [] if results.empty?
      ids = results.map { |r| r[:id].to_i }.uniq
      records_by_id = Games::Game.where(id: ids)
        .includes(:categories, :primary_image, game_companies: :company)
        .index_by(&:id)
      ids.map { |id| records_by_id[id] }.compact
    end
  end
end

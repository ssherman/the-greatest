class Games::GamesController < ApplicationController
  include Cacheable

  layout "games/application"

  before_action :load_ranking_configuration, only: [:show]
  before_action :cache_for_show_page, only: [:show]

  def self.ranking_configuration_class
    Games::RankingConfiguration
  end

  def show
    @game = Games::Game
      .includes(:categories, :platforms, :series, :lists, :child_games, {game_companies: :company})
      .includes(primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}})
      .friendly
      .find(params[:slug])

    @categories_by_type = @game.categories.group_by(&:category_type)
    @developer_names = @game.game_companies.select(&:developer?).map { |gc| gc.company.name }.join(", ")
    @publisher_names = @game.game_companies.select(&:publisher?).map { |gc| gc.company.name }.join(", ")
    @genre_text = @categories_by_type["genre"]&.first&.name || "video games"
    @related_games = @game.series ? @game.series.games.where.not(id: @game.id).to_a : []

    @ranked_item = @ranking_configuration&.ranked_items&.find_by(item: @game)
  end
end

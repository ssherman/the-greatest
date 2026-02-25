# frozen_string_literal: true

class Games::CardComponent < ViewComponent::Base
  include Games::DefaultHelper

  def initialize(game: nil, ranked_item: nil, list_item: nil, ranking_configuration: nil)
    if game.nil? && ranked_item.nil? && list_item.nil?
      raise ArgumentError, "Must provide either game:, ranked_item:, or list_item:"
    end

    @game = game
    @ranked_item = ranked_item
    @list_item = list_item
    @ranking_configuration = ranking_configuration
  end

  private

  attr_reader :game, :ranked_item, :list_item, :ranking_configuration

  def show_rank?
    ranked_item.present? || list_item&.position.present?
  end

  def rank_display
    ranked_item&.rank || list_item&.position
  end

  def item_game
    @item_game ||= game || ranked_item&.item || list_item&.item
  end

  def developer_names
    item_game.game_companies.select(&:developer?).map { |gc| gc.company.name }.join(", ")
  end
end

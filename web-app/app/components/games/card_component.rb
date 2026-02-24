# frozen_string_literal: true

class Games::CardComponent < ViewComponent::Base
  include Games::DefaultHelper

  def initialize(game: nil, ranked_item: nil, ranking_configuration: nil)
    if game.nil? && ranked_item.nil?
      raise ArgumentError, "Must provide either game: or ranked_item:"
    end

    @game = game
    @ranked_item = ranked_item
    @ranking_configuration = ranking_configuration
  end

  private

  attr_reader :game, :ranked_item, :ranking_configuration

  def show_rank?
    ranked_item.present?
  end

  def item_game
    @item_game ||= game || ranked_item.item
  end

  def developer_names
    item_game.game_companies.select(&:developer?).map { |gc| gc.company.name }.join(", ")
  end
end

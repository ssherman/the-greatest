# frozen_string_literal: true

class Music::Artists::CardComponent < ViewComponent::Base
  include Music::DefaultHelper

  def initialize(artist:, ranked_item: nil, ranking_configuration: nil)
    @artist = artist
    @ranked_item = ranked_item
    @ranking_configuration = ranking_configuration
  end

  private

  attr_reader :artist, :ranked_item, :ranking_configuration

  def show_rank?
    ranked_item.present?
  end
end

# frozen_string_literal: true

class Music::Songs::ListItemComponent < ViewComponent::Base
  include Music::DefaultHelper

  def initialize(song:, ranked_item: nil, ranking_configuration: nil, show_index: nil)
    @song = song
    @ranked_item = ranked_item
    @ranking_configuration = ranking_configuration
    @show_index = show_index
  end

  private

  attr_reader :song, :ranked_item, :ranking_configuration, :show_index

  def show_rank?
    ranked_item.present?
  end
end

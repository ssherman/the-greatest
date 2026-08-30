# frozen_string_literal: true

class Books::ReadingGoals::BookCardComponent < ViewComponent::Base
  def initialize(item:, index:)
    @item = item
    @index = index
  end

  private

  attr_reader :item, :index
end

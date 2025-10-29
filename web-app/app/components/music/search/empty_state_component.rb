# frozen_string_literal: true

class Music::Search::EmptyStateComponent < ViewComponent::Base
  def initialize(message:)
    @message = message
  end
end

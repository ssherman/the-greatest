# frozen_string_literal: true

class Search::EmptyStateComponent < ViewComponent::Base
  def initialize(message:)
    @message = message
  end
end

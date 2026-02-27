# frozen_string_literal: true

class Search::EmptyStateComponent < ViewComponent::Base
  def initialize(message:, query: nil)
    @message = message
    @query = query
  end
end

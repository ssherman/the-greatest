# frozen_string_literal: true

# Owner only. :no_history prompts for the wizard; :unavailable (the engine
# failed or came back empty) is omitted rather than shown as an error.
class Books::Profiles::RecommendationsCardComponent < ViewComponent::Base
  def initialize(recommendations:, audience:)
    @recommendations = recommendations
    @audience = audience
  end

  def render?
    return false unless audience == :owner

    [:ok, :no_history].include?(recommendations&.state)
  end

  private

  attr_reader :recommendations, :audience

  def no_history? = recommendations.state == :no_history
end

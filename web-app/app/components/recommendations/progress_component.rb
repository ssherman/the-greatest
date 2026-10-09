# frozen_string_literal: true

module Recommendations
  # The wizard's step bar. Steps 3 and 4 need at least one favorite or read
  # book; until then they render as text so the bar never links to a redirect.
  class ProgressComponent < ViewComponent::Base
    STEPS = [[1, "Favorites"], [2, "History"], [3, "Ratings"], [4, "Preferences"]].freeze
    GATED_FROM = 3

    def initialize(current_step:, unlocked:)
      @current_step = current_step
      @unlocked = unlocked
    end

    def steps
      STEPS.map do |number, label|
        {number: number, label: label, reached: number <= @current_step, linked: @unlocked || number < GATED_FROM}
      end
    end
  end
end

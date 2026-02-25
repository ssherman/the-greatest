# frozen_string_literal: true

class Lists::SimplePenaltySummaryComponent < ViewComponent::Base
  def initialize(ranked_list:)
    @ranked_list = ranked_list
  end

  private

  def penalty_badge_class(penalty_value)
    return "badge-success" if penalty_value < 10
    return "badge-warning" if penalty_value < 25
    "badge-error"
  end
end

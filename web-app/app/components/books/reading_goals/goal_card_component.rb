# frozen_string_literal: true

class Books::ReadingGoals::GoalCardComponent < ViewComponent::Base
  def initialize(goal:, progress:)
    @goal = goal
    @progress = progress
  end

  private

  attr_reader :goal, :progress

  def date_range
    "#{format_date(goal.starts_on)} – #{format_date(goal.ends_on)}"
  end

  def format_date(date)
    date.strftime("%B %-d, %Y")
  end
end

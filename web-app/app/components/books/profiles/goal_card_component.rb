# frozen_string_literal: true

# Every active reading goal, with the books being read right now underneath.
# Goals are the primary content: an owner with none gets a prompt to set one.
class Books::Profiles::GoalCardComponent < ViewComponent::Base
  def initialize(goals:, reading_now:, audience:, data: nil)
    @goals = goals || []
    @reading_now = reading_now
    @audience = audience
    @data = data
  end

  def render?
    goals.any? || reading_books.any? || owner?
  end

  private

  attr_reader :goals, :reading_now, :audience, :data

  def owner? = audience == :owner

  def reading_books = reading_now&.books || []

  # A visitor gets a link only to a goal that is public itself.
  def public_goal_path(goal)
    helpers.books_reading_goal_path(goal) if !owner? && data&.linkable?(goal)
  end

  # A visitor never sees a "Reading goal" heading over nothing: with no goals,
  # "Reading now" is the card's title.
  def goal_section? = goals.any? || owner?

  def prompt_only? = goals.empty? && reading_books.empty?

  def percentage(progress)
    return 0.0 if progress.count.zero?

    (progress.count.fdiv(progress.goal.target_count) * 100).round(1)
  end

  def days_left_text(days)
    case days
    when 0 then "Ends today"
    when 1 then "1 day left"
    else "#{days} days left"
    end
  end
end

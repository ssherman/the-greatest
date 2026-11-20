# frozen_string_literal: true

# Every active reading goal, with the books being read right now underneath.
# Goals are the primary content: an owner with none gets a prompt to set one.
class Books::Profiles::GoalCardComponent < ViewComponent::Base
  def initialize(goals:, reading_now:, audience:)
    @goals = goals || []
    @reading_now = reading_now
    @audience = audience
  end

  def render?
    goals.any? || reading_books.any? || owner?
  end

  private

  attr_reader :goals, :reading_now, :audience

  def owner? = audience == :owner

  def reading_books = reading_now&.books || []

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

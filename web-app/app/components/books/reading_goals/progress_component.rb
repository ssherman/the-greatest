# frozen_string_literal: true

class Books::ReadingGoals::ProgressComponent < ViewComponent::Base
  def initialize(count:, target_count:, percentage:, bar_percentage:)
    @count = count
    @target_count = target_count
    @percentage = percentage
    @bar_percentage = bar_percentage
  end

  private

  attr_reader :count, :target_count, :percentage, :bar_percentage

  def percentage_text
    format_number(percentage)
  end

  def bar_value
    format_number(bar_percentage)
  end

  def progress_label
    "#{count} of #{target_count} books, #{percentage_text}% complete"
  end

  def format_number(value)
    helpers.number_with_precision(value, precision: 1, strip_insignificant_zeros: true)
  end
end

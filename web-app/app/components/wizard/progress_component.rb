# frozen_string_literal: true

class Wizard::ProgressComponent < ViewComponent::Base
  def initialize(steps:, current_step:, import_source: nil)
    @steps = steps
    @current_step = current_step
    @import_source = import_source
  end

  def filtered_steps
    return @steps unless @import_source

    @steps.select { |step| step_applies_to_source?(step[:name]) }
  end

  def step_applies_to_source?(step_name)
    case step_name
    when "parse"
      @import_source == "custom_html"
    else
      true
    end
  end

  # Returns the CSS class for a step based on its completion status.
  # Uses the original step index (from full STEPS array) to compare with current_step,
  # ensuring correct highlighting even when steps are filtered out.
  #
  # @param original_step_index [Integer] The step's index in the full STEPS array
  # @return [String] "step-primary" for completed/current steps, "" for pending
  def step_status(original_step_index)
    if original_step_index < @current_step
      "step-primary"
    elsif original_step_index == @current_step
      "step-primary"
    else
      ""
    end
  end

  # Returns the icon/number to display for a step.
  # Uses original index for completion check, but display position for numbering
  # to show consecutive numbers (1, 2, 3...) regardless of filtered steps.
  #
  # @param original_step_index [Integer] The step's index in the full STEPS array
  # @param display_position [Integer] The step's position in the filtered display list (0-based)
  # @return [String] "✓" for completed steps, 1-based number for pending/current
  def step_icon(original_step_index, display_position)
    if original_step_index < @current_step
      "✓" # Completed step
    else
      (display_position + 1).to_s # 1-based number for pending/current steps
    end
  end

  private

  attr_reader :steps, :current_step, :import_source
end

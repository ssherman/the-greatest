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

  def step_status(step_index)
    if step_index < @current_step
      "step-primary"
    elsif step_index == @current_step
      "step-primary"
    else
      ""
    end
  end

  private

  attr_reader :steps, :current_step, :import_source
end

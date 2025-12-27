# frozen_string_literal: true

class Wizard::NavigationComponent < ViewComponent::Base
  def initialize(list:, step_name:, step_index:, total_steps:, back_enabled: true, next_enabled: true, next_label: "Next →")
    @list = list
    @step_name = step_name
    @step_index = step_index
    @total_steps = total_steps
    @back_enabled = back_enabled
    @next_enabled = next_enabled
    @next_label = next_label
  end

  def show_back_button?
    @step_index > 0 && @back_enabled
  end

  def show_next_button?
    @step_index < @total_steps - 1
  end

  def next_button_disabled?
    !@next_enabled || @list.wizard_manager.step_status(@step_name) == "running"
  end

  private

  attr_reader :list, :step_name, :step_index, :total_steps, :back_enabled, :next_enabled, :next_label
end

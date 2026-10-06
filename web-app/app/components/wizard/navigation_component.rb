# frozen_string_literal: true

class Wizard::NavigationComponent < ViewComponent::Base
  DEFAULT_RESTART_CONFIRM = "Are you sure you want to restart the wizard? Items you have not verified are deleted; verified items are kept."

  attr_reader :next_params

  def initialize(list:, step_name:, step_index:, total_steps:, back_enabled: true, next_enabled: true, next_label: "Next →",
    next_confirm: nil, next_params: {}, restart_confirm: DEFAULT_RESTART_CONFIRM)
    @list = list
    @step_name = step_name
    @step_index = step_index
    @total_steps = total_steps
    @back_enabled = back_enabled
    @next_enabled = next_enabled
    @next_label = next_label
    @next_confirm = next_confirm
    @next_params = next_params
    @restart_confirm = restart_confirm
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

  def next_button_data
    {wizard_step_target: "nextButton", turbo_confirm: @next_confirm}.compact
  end

  def restart_button_data
    {turbo_confirm: @restart_confirm}
  end

  private

  attr_reader :list, :step_name, :step_index, :total_steps, :back_enabled, :next_enabled, :next_label
end

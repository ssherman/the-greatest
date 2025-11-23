# frozen_string_literal: true

class Wizard::ContainerComponent < ViewComponent::Base
  renders_one :header
  renders_one :progress
  renders_many :steps
  renders_one :navigation

  def initialize(wizard_id:, current_step:, total_steps:)
    @wizard_id = wizard_id
    @current_step = current_step
    @total_steps = total_steps
  end

  private

  attr_reader :wizard_id, :current_step, :total_steps
end

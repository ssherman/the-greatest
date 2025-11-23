# frozen_string_literal: true

class Wizard::StepComponent < ViewComponent::Base
  renders_one :step_content
  renders_one :actions

  def initialize(title:, description: nil, step_number: nil, active: true)
    @title = title
    @description = description
    @step_number = step_number
    @active = active
  end

  private

  attr_reader :title, :description, :step_number, :active
end

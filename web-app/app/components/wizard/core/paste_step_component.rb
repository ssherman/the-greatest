# frozen_string_literal: true

class Wizard::Core::PasteStepComponent < ViewComponent::Base
  def initialize(list:, adapter:)
    @list = list
    @adapter = adapter
  end

  def form_path = @adapter.wizard_path(:save_content, @list)

  def batch_mode? = @list.wizard_state&.dig("batch_mode") == true

  private

  attr_reader :list
end

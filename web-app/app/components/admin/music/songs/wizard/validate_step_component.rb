# frozen_string_literal: true

class Admin::Music::Songs::Wizard::ValidateStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  private

  attr_reader :list
end

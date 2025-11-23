# frozen_string_literal: true

class Admin::Music::Songs::Wizard::CompleteStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  private

  attr_reader :list
end

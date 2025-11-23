# frozen_string_literal: true

class Admin::Music::Songs::Wizard::ParseStepComponent < ViewComponent::Base
  def initialize(list:, errors: [])
    @list = list
    @errors = errors
  end

  private

  attr_reader :list, :errors
end

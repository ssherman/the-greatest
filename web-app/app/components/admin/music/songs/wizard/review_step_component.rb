# frozen_string_literal: true

class Admin::Music::Songs::Wizard::ReviewStepComponent < ViewComponent::Base
  def initialize(list:, items: [])
    @list = list
    @items = items
  end

  private

  attr_reader :list, :items
end

# frozen_string_literal: true

# Review step component for Albums wizard.
# Displays all items with filtering, statistics, and renders ItemRowComponent for each item.
#
class Admin::Music::Albums::Wizard::ReviewStepComponent < ViewComponent::Base
  def initialize(list:, items: [], total_count: 0, valid_count: 0, invalid_count: 0, missing_count: 0)
    @list = list
    @items = items
    @total_count = total_count
    @valid_count = valid_count
    @invalid_count = invalid_count
    @missing_count = missing_count
  end

  private

  attr_reader :list, :items, :total_count, :valid_count, :invalid_count, :missing_count

  def percentage(count)
    return 0 if total_count.zero?
    ((count.to_f / total_count) * 100).round(1)
  end
end

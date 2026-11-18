# frozen_string_literal: true

# A list item's finish date. :text is the quiet line under a grid card; :row is the Edit
# page line (a faint "No ... date" placeholder when blank); :table
# is the table cell, with an edit trigger for the owner. The root id lets a
# Turbo Stream replace it in place after an edit.
class UserLists::CompletionDateComponent < ViewComponent::Base
  VARIANTS = %i[text table row].freeze

  def initialize(item:, variant: :table, editable: false)
    @item = item
    @variant = VARIANTS.include?(variant.to_s.to_sym) ? variant.to_s.to_sym : :table
    @editable = editable
  end

  private

  attr_reader :item, :variant, :editable

  def label
    item.user_list.completion_label
  end

  def date
    item.completed_on
  end

  def formatted_date
    date.strftime("%b %-d, %Y")
  end

  def title
    item.listable.try(:title) || item.listable.try(:name)
  end

  def dom_id_value
    helpers.dom_id(item, :completion)
  end
end

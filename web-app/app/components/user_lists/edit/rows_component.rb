# frozen_string_literal: true

# The Edit page's item rows and pager. The container's id is the morph target
# for row writes (Task 9) and the Sortable root (Task 10).
class UserLists::Edit::RowsComponent < ViewComponent::Base
  def initialize(user_list:, items:, pagy:)
    @user_list = user_list
    @items = items
    @pagy = pagy
  end

  private

  attr_reader :user_list, :items, :pagy

  # "2 books", "1 book": the list's own noun, not a generic "items".
  def count_text
    noun = (pagy.count == 1) ? user_list.class.listable_class.model_name.human.downcase : user_list.listable_noun
    "#{pagy.count} #{noun}"
  end
end

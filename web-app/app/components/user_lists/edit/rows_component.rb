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
end

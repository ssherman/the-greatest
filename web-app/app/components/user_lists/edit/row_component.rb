# frozen_string_literal: true

# One item on the Edit page: position badge, cover, title and by-line, the
# finish date (completion lists), and the row's controls. Task 9 fills the
# marked action slots; the drag handle is the Sortable grip (Task 10).
class UserLists::Edit::RowComponent < ViewComponent::Base
  include UserLists::ListableDisplay

  # page is the pager page this row renders on; row actions that move an item
  # across pages need it.
  def initialize(item:, page: 1)
    @item = item
    @page = page
  end

  private

  attr_reader :item, :page

  def listable
    item.listable
  end

  def user_list
    item.user_list
  end

  def completed_on_enabled?
    user_list.completed_on_enabled?
  end
end

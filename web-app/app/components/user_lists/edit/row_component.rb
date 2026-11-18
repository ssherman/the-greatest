# frozen_string_literal: true

# One item on the Edit page: position badge, cover, title and by-line, the
# finish date (completion lists), and the row's controls: the ⋯ menu, the ✕ and
# the drag handle (the Sortable grip). The menu and ✕ post to
# MyListItemsController, whose answers morph the rows in place.
class UserLists::Edit::RowComponent < ViewComponent::Base
  include UserLists::ListableDisplay

  # page is the pager page this row renders on; row actions that move an item
  # across pages need it. item_count is the list's total (the bottom of the
  # move range); the Rows component passes it so rows share one count.
  def initialize(item:, page: 1, item_count: nil)
    @item = item
    @page = page
    @item_count = item_count
  end

  private

  attr_reader :item, :page

  def item_count
    @item_count ||= user_list.user_list_items.count
  end

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

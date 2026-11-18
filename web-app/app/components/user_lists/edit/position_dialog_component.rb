# frozen_string_literal: true

# One dialog shared by every row's "Move to position…" item. The
# user-list-position controller fills the title, range and form action from the
# opener; the form is a Turbo form whose stream answer morphs the rows.
class UserLists::Edit::PositionDialogComponent < ViewComponent::Base
  def initialize(user_list:, page:)
    @user_list = user_list
    @page = page
  end

  private

  attr_reader :page

  def item_count
    @user_list.user_list_items.count
  end
end

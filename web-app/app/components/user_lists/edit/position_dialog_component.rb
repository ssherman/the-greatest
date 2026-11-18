# frozen_string_literal: true

# One dialog shared by every row's "Move to position…" item. The
# user-list-position controller fills the title, range and form action from the
# opener; the form is a Turbo form whose stream answer morphs the rows.
class UserLists::Edit::PositionDialogComponent < ViewComponent::Base
  def initialize(user_list:, page:, item_count:)
    @user_list = user_list
    @page = page
    @item_count = item_count
  end

  private

  attr_reader :page, :item_count
end

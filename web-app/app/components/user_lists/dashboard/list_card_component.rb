# frozen_string_literal: true

class UserLists::Dashboard::ListCardComponent < ViewComponent::Base
  def initialize(user_list:, item_count:)
    @user_list = user_list
    @item_count = item_count
  end

  private

  attr_reader :user_list, :item_count

  # Lucide icon name for a default list's list_type, or nil for custom lists
  # (which show a "Custom" tag instead).
  def icon_name
    user_list.class.list_type_icons[user_list.list_type.to_sym]
  end
end

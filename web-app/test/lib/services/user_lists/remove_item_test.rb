require "test_helper"

module Services
  module UserLists
    class RemoveItemTest < ActiveSupport::TestCase
      test "removing a completion-capable item reports its old date and nil new date" do
        item = user_lists(:regular_user_books_read).user_list_items.create!(
          listable: books_books(:cannery_row), completed_on: Date.new(2026, 8, 1)
        )

        result = RemoveItem.call(item: item)

        assert result.success?
        assert_equal Date.new(2026, 8, 1), result.data[:old_completed_on]
        assert_nil result.data[:new_completed_on]
        refute UserListItem.exists?(item.id)
      end

      test "removing another list's item reports nil completion dates" do
        item = user_list_items(:regular_user_fav_album_1)

        result = RemoveItem.call(item: item)

        assert result.success?
        assert_nil result.data[:old_completed_on]
        assert_nil result.data[:new_completed_on]
      end
    end
  end
end

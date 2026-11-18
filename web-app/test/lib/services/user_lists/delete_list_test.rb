require "test_helper"

module Services
  module UserLists
    class DeleteListTest < ActiveSupport::TestCase
      test "deletes a custom list and its items" do
        list = user_lists(:regular_user_custom_albums)

        assert_difference "UserListItem.count", -1 do
          result = DeleteList.call(list: list)
          assert result.success?
        end
        refute UserList.exists?(list.id)
      end

      test "refuses a default list" do
        list = user_lists(:regular_user_books_read)

        result = DeleteList.call(list: list)

        refute result.success?
        assert_equal ["A default list cannot be deleted"], result.errors
        assert UserList.exists?(list.id)
      end

      test "touches the owner" do
        list = user_lists(:regular_user_custom_albums)
        user = list.user
        user.update_columns(updated_at: 1.day.ago)

        DeleteList.call(list: list)

        assert_in_delta Time.current, user.reload.updated_at, 5.seconds
      end
    end
  end
end

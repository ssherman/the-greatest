require "test_helper"

module Services
  module UserLists
    class AddItemTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @book = books_books(:cannery_row)
        @read_list = user_lists(:regular_user_books_read)
        @reading_list = ::Books::UserList.find_or_create_by!(user: @user, list_type: :reading) do |list|
          list.name = ::Books::UserList.default_list_name_for(:reading)
        end
      end

      test "direct Read addition stays undated" do
        result = AddItem.call(user_list: @read_list, listable: @book, today: Date.new(2026, 8, 26))

        assert result.success?
        assert_nil result.data[:item].completed_on
        refute result.data[:transitioned]
      end

      test "Reading to Read removes Reading and stamps today" do
        reading_item = @reading_list.user_list_items.create!(listable: @book)

        result = AddItem.call(user_list: @read_list, listable: @book, today: Date.new(2026, 8, 26))

        assert result.success?
        refute UserListItem.exists?(reading_item.id)
        assert_equal Date.new(2026, 8, 26), result.data[:item].completed_on
        assert result.data[:transitioned]
      end

      test "a stale Reading membership never overwrites an existing Read date" do
        read_item = @read_list.user_list_items.create!(listable: @book, completed_on: Date.new(1999, 1, 2))
        reading_item = @reading_list.user_list_items.create!(listable: @book)

        result = AddItem.call(user_list: @read_list, listable: @book)

        assert result.success?
        refute UserListItem.exists?(reading_item.id)
        assert_equal Date.new(1999, 1, 2), read_item.reload.completed_on
      end

      test "a failed target save rolls back source removal" do
        source = @reading_list.user_list_items.create!(listable: @book)
        UserListItem.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(UserListItem.new))

        result = AddItem.call(user_list: @read_list, listable: @book)

        refute result.success?
        assert UserListItem.exists?(source.id)
      end

      test "duplicate without a transition returns the stable failure result" do
        @read_list.user_list_items.create!(listable: @book)

        result = AddItem.call(user_list: @read_list, listable: @book)

        refute result.success?
        assert_nil result.data
        assert_equal ["Item already in list"], result.errors
      end

      test "removes every declared source membership" do
        duplicate_reading_list = ::Books::UserList.create!(
          user: users(:editor_user), name: "Other user's Reading", list_type: :reading
        )
        source = @reading_list.user_list_items.create!(listable: @book)
        duplicate_reading_list.user_list_items.create!(listable: books_books(:of_mice_and_men))

        result = AddItem.call(user_list: @read_list, listable: @book)

        assert result.success?
        assert_equal [source.id], result.data[:removed_items].map(&:id)
        assert_equal 1, duplicate_reading_list.user_list_items.count
      end
    end
  end
end

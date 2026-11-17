require "test_helper"

module Services
  module UserLists
    class UpdateItemTest < ActiveSupport::TestCase
      setup do
        @read = user_lists(:regular_user_books_read)
        @item = @read.user_list_items.create!(listable: books_books(:war_and_peace))
      end

      test "sets and clears completed_on" do
        result = UpdateItem.call(item: @item, completed_on: Date.new(2024, 3, 1))
        assert result.success?
        assert_equal Date.new(2024, 3, 1), @item.reload.completed_on

        UpdateItem.call(item: @item, completed_on: nil)
        assert_nil @item.reload.completed_on
      end

      test "moves the item to a position" do
        result = UpdateItem.call(item: @item, position: 1)

        assert result.success?
        assert_equal 1, @item.reload.position
        assert @read.reload.manually_ordered
      end

      test "an out-of-range position is a failure" do
        result = UpdateItem.call(item: @item, position: 99)

        refute result.success?
        assert_equal 2, @item.reload.position
      end

      test "an invalid completed_on fails and leaves the position unmoved" do
        result = UpdateItem.call(item: @item, completed_on: "nope", position: 1)

        refute result.success?
        assert_equal 2, @item.reload.position
      end

      test "a valid completed_on with an out-of-range position rolls the date back" do
        result = UpdateItem.call(item: @item, completed_on: Date.new(2024, 3, 1), position: 99)

        refute result.success?
        assert_nil @item.reload.completed_on
      end

      test "an item deleted underneath the call reads as no longer existing" do
        stale = UserListItem.find(@item.id)
        UserListItem.where(id: @item.id).delete_all

        result = UpdateItem.call(item: stale, position: 1)

        refute result.success?
        assert_equal ["Item no longer exists"], result.errors
      end
    end
  end
end

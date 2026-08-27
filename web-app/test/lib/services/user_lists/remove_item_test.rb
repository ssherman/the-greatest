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
        assert_success_data(result, item: item, old_completed_on: Date.new(2026, 8, 1))
      end

      test "removing another list's item reports nil completion dates" do
        item = user_list_items(:regular_user_fav_album_1)

        result = RemoveItem.call(item: item)

        assert result.success?
        assert_nil result.data[:old_completed_on]
        assert_nil result.data[:new_completed_on]
        assert_success_data(result, item: item, old_completed_on: nil)
      end

      test "a destroy abort returns a failure without deleting the item" do
        item = user_list_items(:regular_user_fav_album_1)
        UserListItem.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new("destroy aborted", UserListItem.new))

        result = RemoveItem.call(item: item)

        refute result.success?
        assert_equal ["Mutation could not be completed"], result.errors
        assert UserListItem.exists?(item.id)
      end

      test "a stale item returns a failure result" do
        item = user_list_items(:regular_user_fav_album_1)
        item.destroy!

        result = RemoveItem.call(item: item)

        refute result.success?
        assert_equal ["Item no longer exists"], result.errors
      end

      private

      def assert_success_data(result, item:, old_completed_on:)
        assert_equal [:item, :listable, :new_completed_on, :old_completed_on, :removed_items, :transitioned], result.data.keys.sort
        assert_equal [], result.errors
        assert_equal item, result.data[:item]
        assert_equal item.listable, result.data[:listable]
        assert_equal [], result.data[:removed_items]
        old_completed_on.nil? ? assert_nil(result.data[:old_completed_on]) : assert_equal(old_completed_on, result.data[:old_completed_on])
        assert_nil result.data[:new_completed_on]
        refute result.data[:transitioned]
      end
    end
  end
end

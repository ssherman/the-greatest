require "test_helper"

module Services
  module UserLists
    class MoveItemTest < ActiveSupport::TestCase
      setup do
        @list = ::Books::UserList.create!(user: users(:regular_user), list_type: :reading, name: "Reading")
      end

      def add(*names) = names.map { |name| @list.user_list_items.create!(listable: books_books(name)) }

      test "shifts siblings, keeps positions contiguous over hidden items and marks the list manually ordered" do
        items = add(:war_and_peace, :crime_and_punishment, :cannery_row, :of_mice_and_men)
        books_books(:cannery_row).update_columns(provisional: true)

        result = MoveItem.call(item: items[3], to_position: 1)

        assert result.success?
        assert_equal [items[3], items[0], items[1], items[2]].map(&:id), @list.user_list_items.reload.map(&:id)
        assert_equal [1, 2, 3, 4], @list.user_list_items.map(&:position)
        assert @list.reload.manually_ordered
        assert_equal 2, items[0].reload.position
        refute items[3].changed?

        MoveItem.call(item: items[3], to_position: 4)
        assert_equal [1, 2, 3, 4], @list.user_list_items.reload.map(&:position)
        assert_equal items.map(&:id), @list.user_list_items.map(&:id)
      end

      test "a move to the same position changes nothing" do
        items = add(:war_and_peace, :crime_and_punishment)
        stamp = 1.day.ago.change(usec: 0)
        @list.update_columns(updated_at: stamp)

        assert MoveItem.call(item: items[1], to_position: 2).success?

        @list.reload
        assert_not @list.manually_ordered
        assert_equal stamp, @list.updated_at
        assert_equal [1, 2], @list.user_list_items.reload.map(&:position)
      end

      test "a position outside 1..count is a failure and moves nothing" do
        items = add(:war_and_peace, :crime_and_punishment, :cannery_row, :of_mice_and_men)

        [5, 0, "2"].each do |position|
          result = MoveItem.call(item: items[0], to_position: position)
          refute result.success?
          assert_equal ["Position must be between 1 and 4"], result.errors
        end
        assert_equal 1, items[0].reload.position
      end

      test "a real move touches the list" do
        items = add(:war_and_peace, :cannery_row)
        @list.update_columns(updated_at: 1.day.ago)

        MoveItem.call(item: items[1], to_position: 1)

        assert_operator @list.reload.updated_at, :>, 1.hour.ago
      end

      test "an item deleted underneath the call is a stale-item failure" do
        items = add(:war_and_peace, :cannery_row)
        stale = UserListItem.find(items[0].id)
        UserListItem.where(id: stale.id).delete_all

        result = MoveItem.call(item: stale, to_position: 1)

        refute result.success?
        assert_equal ["Item no longer exists"], result.errors
      end
    end
  end
end

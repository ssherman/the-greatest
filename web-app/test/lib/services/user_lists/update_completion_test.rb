require "test_helper"

module Services
  module UserLists
    class UpdateCompletionTest < ActiveSupport::TestCase
      setup do
        @item = user_lists(:regular_user_books_read).user_list_items.create!(listable: books_books(:cannery_row))
      end

      test "sets replaces and clears a completion date" do
        set = UpdateCompletion.call(item: @item, completed_on: "2026-08-01")
        replace = UpdateCompletion.call(item: @item.reload, completed_on: "2026-08-02")
        clear = UpdateCompletion.call(item: @item.reload, completed_on: "")

        assert_equal [nil, Date.new(2026, 8, 1)], [set.data[:old_completed_on], set.data[:new_completed_on]]
        assert_equal [Date.new(2026, 8, 1), Date.new(2026, 8, 2)], [replace.data[:old_completed_on], replace.data[:new_completed_on]]
        assert_equal [Date.new(2026, 8, 2), nil], [clear.data[:old_completed_on], clear.data[:new_completed_on]]
      end

      test "an invalid ISO date fails without changing a stored value" do
        @item.update!(completed_on: Date.new(2026, 8, 1))

        result = UpdateCompletion.call(item: @item, completed_on: "August 2, 2026")

        refute result.success?
        assert_equal ["Completion date is invalid"], result.errors
        assert_equal Date.new(2026, 8, 1), @item.reload.completed_on
      end

      test "rejects lists without completion-date capability" do
        item = user_list_items(:regular_user_fav_album_1)

        result = UpdateCompletion.call(item: item, completed_on: "2026-08-01")

        refute result.success?
        assert_nil result.data
        assert_nil item.reload.completed_on
      end
    end
  end
end

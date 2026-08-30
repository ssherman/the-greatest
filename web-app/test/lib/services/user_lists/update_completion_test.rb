require "test_helper"

module Services
  module UserLists
    class UpdateCompletionTest < ActiveSupport::TestCase
      setup do
        @item = user_lists(:regular_user_books_read).user_list_items.create!(listable: books_books(:cannery_row))
        @reading_list = ::Books::UserList.find_or_create_by!(user: users(:regular_user), list_type: :reading) do |list|
          list.name = ::Books::UserList.default_list_name_for(:reading)
        end
      end

      test "sets replaces and clears a completion date" do
        set = UpdateCompletion.call(item: @item, completed_on: "2026-08-01")
        replace = UpdateCompletion.call(item: @item.reload, completed_on: "2026-08-02")
        clear = UpdateCompletion.call(item: @item.reload, completed_on: "")

        assert_equal [nil, Date.new(2026, 8, 1)], [set.data[:old_completed_on], set.data[:new_completed_on]]
        assert_equal [Date.new(2026, 8, 1), Date.new(2026, 8, 2)], [replace.data[:old_completed_on], replace.data[:new_completed_on]]
        assert_equal [Date.new(2026, 8, 2), nil], [clear.data[:old_completed_on], clear.data[:new_completed_on]]
        [set, replace, clear].each { |result| assert result.success? }
        assert_success_data(set, old_completed_on: nil, new_completed_on: Date.new(2026, 8, 1))
        assert_success_data(replace, old_completed_on: Date.new(2026, 8, 1), new_completed_on: Date.new(2026, 8, 2))
        assert_success_data(clear, old_completed_on: Date.new(2026, 8, 2), new_completed_on: nil)
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
        assert_equal ["Completion dates are not enabled for this list"], result.errors
      end

      test "a stale cached Read association cannot update a row moved to Reading" do
        @item.user_list
        UserListItem.where(id: @item.id).update_all(user_list_id: @reading_list.id) # rubocop:disable Rails/SkipsModelValidations

        result = UpdateCompletion.call(item: @item, completed_on: "2026-08-01")

        refute result.success?
        assert_equal ["Completion dates are not enabled for this list"], result.errors
        assert_nil @item.reload.completed_on
      end

      test "an update save abort returns a failure without changing the completion date" do
        UserListItem.any_instance.stubs(:update!).raises(ActiveRecord::RecordNotSaved.new("save aborted", UserListItem.new))

        result = UpdateCompletion.call(item: @item, completed_on: "2026-08-01")

        refute result.success?
        assert_equal ["Mutation could not be completed"], result.errors
        assert_nil @item.reload.completed_on
      end

      test "a stale item returns a failure result" do
        @item.destroy!

        result = UpdateCompletion.call(item: @item, completed_on: "2026-08-01")

        refute result.success?
        assert_equal ["Item no longer exists"], result.errors
      end

      private

      def assert_success_data(result, old_completed_on:, new_completed_on:)
        assert_equal [:item, :listable, :new_completed_on, :old_completed_on, :removed_items, :transitioned], result.data.keys.sort
        assert_equal [], result.errors
        assert_equal @item, result.data[:item]
        assert_equal @item.listable, result.data[:listable]
        assert_equal [], result.data[:removed_items]
        assert_optional_date old_completed_on, result.data[:old_completed_on]
        assert_optional_date new_completed_on, result.data[:new_completed_on]
        refute result.data[:transitioned]
      end

      def assert_optional_date(expected, actual)
        expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
      end
    end
  end
end

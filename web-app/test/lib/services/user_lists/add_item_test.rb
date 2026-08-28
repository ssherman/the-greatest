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
        assert_success_data(result, item: result.data[:item], removed_items: [], old_completed_on: nil, new_completed_on: nil, transitioned: false)
      end

      test "Reading to Read removes Reading and stamps today" do
        reading_item = @reading_list.user_list_items.create!(listable: @book)

        result = AddItem.call(user_list: @read_list, listable: @book, today: Date.new(2026, 8, 26))

        assert result.success?
        refute UserListItem.exists?(reading_item.id)
        assert_equal Date.new(2026, 8, 26), result.data[:item].completed_on
        assert result.data[:transitioned]
        assert_success_data(
          result,
          item: result.data[:item],
          removed_items: [reading_item],
          old_completed_on: nil,
          new_completed_on: Date.new(2026, 8, 26),
          transitioned: true
        )
      end

      test "a stale Reading membership never overwrites an existing Read date" do
        read_item = @read_list.user_list_items.create!(listable: @book, completed_on: Date.new(1999, 1, 2))
        reading_item = @reading_list.user_list_items.create!(listable: @book)

        result = AddItem.call(user_list: @read_list, listable: @book)

        assert result.success?
        refute UserListItem.exists?(reading_item.id)
        assert_equal Date.new(1999, 1, 2), read_item.reload.completed_on
        assert_success_data(
          result,
          item: read_item,
          removed_items: [reading_item],
          old_completed_on: Date.new(1999, 1, 2),
          new_completed_on: Date.new(1999, 1, 2),
          transitioned: true
        )
      end

      test "a failed target save rolls back source removal" do
        source = @reading_list.user_list_items.create!(listable: @book)
        UserListItem.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(UserListItem.new))

        result = AddItem.call(user_list: @read_list, listable: @book)

        refute result.success?
        assert UserListItem.exists?(source.id)
      end

      test "a target uniqueness abort rolls back source removal" do
        source = @reading_list.user_list_items.create!(listable: @book)
        UserListItem.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate"))

        result = AddItem.call(user_list: @read_list, listable: @book)

        refute result.success?
        assert_equal ["Item already in list"], result.errors
        assert UserListItem.exists?(source.id)
      end

      test "a database uniqueness failure under the owner lock leaves the outer transaction usable" do
        source = @reading_list.user_list_items.create!(listable: @book)
        duplicate_attributes = {
          user_list_id: @read_list.id,
          listable_type: @book.class.base_class.name,
          listable_id: @book.id,
          position: 1,
          created_at: Time.current,
          updated_at: Time.current
        }
        force_duplicate = proc do
          UserListItem.insert_all!([duplicate_attributes])
          UserListItem.insert_all!([duplicate_attributes])
        end
        UserListItem.set_callback(:save, :before, force_duplicate)

        @user.with_lock do
          result = AddItem.call(user_list: @read_list, listable: @book)

          refute result.success?
          assert_equal ["Item already in list"], result.errors
          assert UserListItem.exists?(source.id)
          assert_equal [source.id], UserListItem.where(id: source.id).pluck(:id)
        end
      ensure
        UserListItem.skip_callback(:save, :before, force_duplicate) if force_duplicate
      end

      test "a completed add inside the owner lock is visible to the reading goal query" do
        @reading_list.user_list_items.create!(listable: @book)
        goal = ::Books::ReadingGoal.create!(
          user: @user,
          name: "Locked goal",
          target_count: 1,
          starts_on: Date.new(2026, 1, 1),
          ends_on: Date.new(2026, 12, 31),
          public: true
        )

        @user.with_lock do
          before_count = Services::Books::ReadingGoals::ProgressQuery.call(goal: goal).count
          result = AddItem.call(user_list: @read_list, listable: @book, today: Date.new(2026, 8, 26))

          assert result.success?
          assert_equal before_count + 1, Services::Books::ReadingGoals::ProgressQuery.call(goal: goal).count
        end
      end

      test "a target save abort rolls back source removal" do
        source = @reading_list.user_list_items.create!(listable: @book)
        UserListItem.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotSaved.new("save aborted", UserListItem.new))

        result = AddItem.call(user_list: @read_list, listable: @book)

        refute result.success?
        assert_equal ["Mutation could not be completed"], result.errors
        assert UserListItem.exists?(source.id)
      end

      test "a source destroy abort leaves all memberships unchanged" do
        source = @reading_list.user_list_items.create!(listable: @book)
        UserListItem.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed.new("destroy aborted", UserListItem.new))

        result = AddItem.call(user_list: @read_list, listable: @book)

        refute result.success?
        assert_equal ["Mutation could not be completed"], result.errors
        assert UserListItem.exists?(source.id)
        assert_nil @read_list.user_list_items.find_by(listable: @book)
      end

      test "duplicate without a transition returns the stable failure result" do
        @read_list.user_list_items.create!(listable: @book)

        result = AddItem.call(user_list: @read_list, listable: @book)

        refute result.success?
        assert_nil result.data
        assert_equal ["Item already in list"], result.errors
      end

      test "removes every declared source membership" do
        second_reading_list = ::Books::UserList.new(
          user: @user, name: "Second Reading", list_type: :reading
        )
        second_reading_list.save!(validate: false)
        other_user_reading_list = ::Books::UserList.create!(
          user: users(:editor_user), name: "Other user's Reading", list_type: :reading
        )
        first_source = @reading_list.user_list_items.create!(listable: @book)
        second_source = second_reading_list.user_list_items.create!(listable: @book)
        other_user_source = other_user_reading_list.user_list_items.create!(listable: @book)

        result = AddItem.call(user_list: @read_list, listable: @book)

        assert result.success?
        assert_equal [first_source.id, second_source.id].sort, result.data[:removed_items].map(&:id).sort
        refute UserListItem.exists?(first_source.id)
        refute UserListItem.exists?(second_source.id)
        assert UserListItem.exists?(other_user_source.id)
        assert_success_data(
          result,
          item: result.data[:item],
          removed_items: [first_source, second_source],
          old_completed_on: nil,
          new_completed_on: Date.current,
          transitioned: true
        )
      end

      private

      def assert_success_data(result, item:, removed_items:, old_completed_on:, new_completed_on:, transitioned:)
        assert_equal [:item, :listable, :new_completed_on, :old_completed_on, :removed_items, :transitioned], result.data.keys.sort
        assert_equal [], result.errors
        assert_equal item, result.data[:item]
        assert_equal item.listable, result.data[:listable]
        assert_equal removed_items.map(&:id).sort, result.data[:removed_items].map(&:id).sort
        assert_optional_date old_completed_on, result.data[:old_completed_on]
        assert_optional_date new_completed_on, result.data[:new_completed_on]
        assert_equal transitioned, result.data[:transitioned]
      end

      def assert_optional_date(expected, actual)
        expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
      end
    end
  end
end

require "test_helper"

module Services
  module UserLists
    class RestoreItemTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @list = user_lists(:regular_user_books_read)
        @list.user_list_items.destroy_all
        @books = [:war_and_peace, :crime_and_punishment, :cannery_row, :got].map { |name| books_books(name) }
        @books.each_with_index do |book, index|
          @list.user_list_items.create!(listable: book, completed_on: (index == 2) ? Date.new(2024, 3, 3) : nil)
        end
        @list.update_columns(manually_ordered: false)
        @book = @books[2]
      end

      test "restores a removed book to its old position and date" do
        position = @list.user_list_items.find_by(listable: @book).position
        RemoveItems.call(user_list: @list, listables: [@book])

        result = RestoreItem.call(user_list: @list, listable: @book, position: position, completed_on: Date.new(2024, 3, 3))

        assert result.success?, result.errors.inspect
        assert_equal [3, Date.new(2024, 3, 3)], [result.data[:item].position, result.data[:item].completed_on]
        assert_equal @books.map(&:id), @list.user_list_items.reload.order(:position).map(&:listable_id)
      end

      test "restores a nil completion date as nil" do
        RemoveItems.call(user_list: @list, listables: [@books[0]])

        result = RestoreItem.call(user_list: @list, listable: @books[0], position: 1, completed_on: nil)

        assert result.success?, result.errors.inspect
        assert_nil result.data[:item].completed_on
      end

      test "fails without a duplicate when the item is already on the list" do
        result = RestoreItem.call(user_list: @list, listable: @book, position: 1, completed_on: nil)

        refute result.success?
        assert_equal ["Already back on this list"], result.errors
        assert_equal 1, @list.user_list_items.where(listable: @book).count
      end

      test "clamps a position past the end" do
        RemoveItems.call(user_list: @list, listables: [@book])

        result = RestoreItem.call(user_list: @list, listable: @book, position: 99, completed_on: nil)

        assert result.success?
        assert_equal 4, result.data[:item].position
      end

      test "leaves manually_ordered unchanged, even after a real move" do
        RemoveItems.call(user_list: @list, listables: [@book])
        RestoreItem.call(user_list: @list, listable: @book, position: 1, completed_on: nil)
        refute @list.reload.manually_ordered?

        @list.update_columns(manually_ordered: true)
        RemoveItems.call(user_list: @list, listables: [@book])
        RestoreItem.call(user_list: @list, listable: @book, position: 1, completed_on: nil)
        assert @list.reload.manually_ordered?
      end

      test "restores the original created_at, and ignores an unparseable one" do
        RemoveItems.call(user_list: @list, listables: [@book])
        at = Time.utc(2023, 5, 6, 7, 8, 9)

        result = RestoreItem.call(user_list: @list, listable: @book, position: 3, completed_on: nil, added_at: at.iso8601)
        assert_equal at, result.data[:item].created_at

        RemoveItems.call(user_list: @list, listables: [@book])
        result = RestoreItem.call(user_list: @list, listable: @book, position: 3, completed_on: nil, added_at: "garbage")
        assert result.success?
        assert_operator result.data[:item].created_at, :>, 1.day.ago
      end

      test "refuses, and moves nothing, when the book now sits on a transition source list" do
        RemoveItems.call(user_list: @list, listables: [@book])
        reading = ::Books::UserList.find_or_create_by!(user: @user, list_type: :reading) { |l| l.name = "Reading" }
        reading.user_list_items.create!(listable: @book)

        result = RestoreItem.call(user_list: @list, listable: @book, position: 3, completed_on: nil)

        refute result.success?
        assert_equal 1, reading.user_list_items.where(listable: @book).count
        assert_equal 0, @list.user_list_items.where(listable: @book).count
      end

      test "tracks the reading goal change" do
        RemoveItems.call(user_list: @list, listables: [@book])
        date = Date.new(2024, 3, 3)
        Services::Books::ReadingGoals::CompletionChangeInvalidator.stubs(:call).returns([])
        Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call)
          .with(has_entries(old_completed_on: nil, new_completed_on: date)).returns([])

        RestoreItem.call(user_list: @list, listable: @book, position: 3, completed_on: date)
      end
    end
  end
end

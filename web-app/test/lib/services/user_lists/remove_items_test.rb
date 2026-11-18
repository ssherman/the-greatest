require "test_helper"

module Services
  module UserLists
    class RemoveItemsTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @list = ::Books::UserList.find_or_create_by!(user: @user, list_type: :reading) do |list|
          list.name = ::Books::UserList.default_list_name_for(:reading)
        end
        @war = books_books(:war_and_peace)
        @crime = books_books(:crime_and_punishment)
        @row = books_books(:cannery_row)
        [@war, @crime, @row].each { |book| @list.user_list_items.create!(listable: book) }
      end

      test "removes present books, reports absent ones, and leaves positions contiguous" do
        result = RemoveItems.call(user_list: @list, listables: [@war, books_books(:got)])

        assert result.success?
        assert_equal %w[removed not_present], result.data[:outcomes].map { |o| o[:outcome] }
        assert_equal [@crime.id, @row.id], @list.user_list_items.reload.map(&:listable_id)
        assert_equal [1, 2], @list.user_list_items.map(&:position)
      end

      test "a RemoveItem failure on the second rolls back the first" do
        calls = 0
        RemoveItem.stubs(:call).with do |item:|
          calls += 1
          item.destroy! if calls == 1
          true
        end.returns(
          MutationResult.new(success?: true, data: {listable: @war, old_completed_on: nil, new_completed_on: nil}, errors: []),
          MutationResult.failure(["boom"])
        )

        result = RemoveItems.call(user_list: @list, listables: [@war, @crime])

        refute result.success?
        assert_equal ["boom"], result.errors
        assert_equal 3, @list.user_list_items.reload.count
      end
    end
  end
end

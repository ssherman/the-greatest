# frozen_string_literal: true

require "test_helper"

module Services
  module UserLists
    class BackfillManuallyOrderedTest < ActiveSupport::TestCase
      # Fixtures ship user lists whose positions already match insertion order,
      # which is exactly the "not curated" case, so they need no special handling.
      setup do
        @user = users(:editor_user)
        @list = ::Books::UserList.create!(
          user: @user, list_type: :favorites, name: "My Favorite Books"
        )
      end

      def add_item(book, position:, created_at:)
        ::UserListItem.create!(
          user_list: @list, listable: book, position: position
        ).update_columns(created_at: created_at, updated_at: created_at)
      end

      test "leaves a list whose position order matches insertion order alone" do
        add_item(books_books(:war_and_peace), position: 1, created_at: 3.days.ago)
        add_item(books_books(:got), position: 2, created_at: 2.days.ago)
        add_item(books_books(:clash), position: 3, created_at: 1.day.ago)

        BackfillManuallyOrdered.call

        refute @list.reload.manually_ordered?
      end

      test "flags a list whose position order differs from insertion order" do
        # Added oldest-first, but the newest item sits at position 1 -- the user
        # moved it there.
        add_item(books_books(:war_and_peace), position: 2, created_at: 3.days.ago)
        add_item(books_books(:got), position: 3, created_at: 2.days.ago)
        add_item(books_books(:clash), position: 1, created_at: 1.day.ago)

        BackfillManuallyOrdered.call

        assert @list.reload.manually_ordered?
      end

      test "ignores non-favorites lists" do
        read_list = ::Books::UserList.create!(
          user: @user, list_type: :read, name: "Books I've Read"
        )
        item = ::UserListItem.create!(
          user_list: read_list, listable: books_books(:war_and_peace), position: 2
        )
        item.update_columns(created_at: 1.day.ago, updated_at: 1.day.ago)
        ::UserListItem.create!(
          user_list: read_list, listable: books_books(:got), position: 1
        ).update_columns(created_at: 3.days.ago, updated_at: 3.days.ago)

        BackfillManuallyOrdered.call

        refute read_list.reload.manually_ordered?
      end

      test "returns the number of lists it flagged" do
        add_item(books_books(:war_and_peace), position: 2, created_at: 2.days.ago)
        add_item(books_books(:got), position: 1, created_at: 1.day.ago)

        assert_equal 1, BackfillManuallyOrdered.call
      end

      test "is idempotent" do
        add_item(books_books(:war_and_peace), position: 2, created_at: 2.days.ago)
        add_item(books_books(:got), position: 1, created_at: 1.day.ago)

        BackfillManuallyOrdered.call
        assert_equal 0, BackfillManuallyOrdered.call
        assert @list.reload.manually_ordered?
      end
    end
  end
end

require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class LegacyChoiceTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @read = user_lists(:regular_user_books_read)
          @book = books_books(:war_and_peace)
          UserListItem.where(listable: @book).delete_all # the favorites fixture holds it
        end

        def holds(book, value)
          ::Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: value)
        end

        test "the book holding the id that is on the user's lists" do
          holds(@book, "656")
          UserListItem.create!(user_list: @read, listable: @book)

          assert_equal @book, LegacyChoice.call(goodreads_book_id: 656, user_id: @user.id)
        end

        test "a slug-form id is legacy's too" do
          holds(@book, "656-war-and-peace")
          UserListItem.create!(user_list: @read, listable: @book)

          assert_equal @book, LegacyChoice.call(goodreads_book_id: 656, user_id: @user.id)
        end

        test "a holder the user does not have is not legacy's choice for that user" do
          holds(@book, "656")

          assert_nil LegacyChoice.call(goodreads_book_id: 656, user_id: @user.id)
        end

        test "a longer id sharing the digits is not the same id" do
          holds(@book, "6567")
          UserListItem.create!(user_list: @read, listable: @book)

          assert_nil LegacyChoice.call(goodreads_book_id: 656, user_id: @user.id)
        end
      end
    end
  end
end

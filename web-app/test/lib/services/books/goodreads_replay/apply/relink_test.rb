require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class RelinkTest < ActiveSupport::TestCase
          setup do
            @user = users(:regular_user)
            @read = user_lists(:regular_user_books_read)
            @from = books_books(:war_and_peace)
            @to = books_books(:of_mice_and_men)
            UserListItem.where(listable: [@from, @to]).delete_all
            Review.where(reviewable: [@from, @to]).delete_all
          end

          def verdict(user_id: @user.id, from: @from, to: @to, strip: [])
            ::Books::RepairVerdict.create!(kind: :relink, subject_key: "user:#{user_id}:book:#{from.id}:goodreads:1",
              decided_by: :ai, status: :approved,
              payload: {"user_id" => user_id, "from_book_id" => from.id, "to_book_id" => to.id, "goodreads_book_id" => 1,
                        "strip_identifiers" => strip})
          end

          test "moves the user's list items and review from the wrong book to the right one" do
            item = UserListItem.create!(user_list: @read, listable: @from, completed_on: Date.new(2025, 3, 1))
            review = Review.create!(user: @user, reviewable: @from, rating: 4)

            result = Relink.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_equal @to, item.reload.listable
            assert_equal @to, review.reload.reviewable
          end

          test "on a list holding both books, keeps the right one's item and fills its blank date from the wrong one's" do
            UserListItem.create!(user_list: @read, listable: @from, completed_on: Date.new(2025, 3, 1))
            kept = UserListItem.create!(user_list: @read, listable: @to)

            Relink.call(verdict: verdict)

            assert_equal [kept.id], UserListItem.where(user_list: @read, listable: [@from, @to]).pluck(:id)
            assert_equal Date.new(2025, 3, 1), kept.reload.completed_on
          end

          test "keeps a review the user already wrote on the right book" do
            Review.create!(user: @user, reviewable: @from, rating: 2)
            kept = Review.create!(user: @user, reviewable: @to, rating: 5)

            Relink.call(verdict: verdict)

            assert_equal [kept.id], Review.where(user: @user, reviewable: [@from, @to]).pluck(:id)
          end

          test "another user's items on the wrong book stay where they are" do
            other_list = ::Books::UserList.create!(user: users(:editor_user), name: "Shelf", list_type: :custom)
            other = UserListItem.create!(user_list: other_list, listable: @from)
            UserListItem.create!(user_list: @read, listable: @from)

            Relink.call(verdict: verdict)

            assert_equal @from, other.reload.listable
          end

          test "moves the row's identifiers when the payload says legacy's identifier was wrong" do
            ::Identifier.create!(identifiable: @from, identifier_type: :books_work_goodreads_id, value: "777")
            UserListItem.create!(user_list: @read, listable: @from)

            Relink.call(verdict: verdict(strip: [["books_work_goodreads_id", "777"]]))

            refute @from.identifiers.exists?(identifier_type: :books_work_goodreads_id, value: "777")
            assert @to.identifiers.exists?(identifier_type: :books_work_goodreads_id, value: "777")
          end

          test "applying twice does nothing the second time" do
            UserListItem.create!(user_list: @read, listable: @from)
            relink = verdict
            Relink.call(verdict: relink)

            assert_equal :noop, Relink.call(verdict: relink).data[:outcome]
          end

          test "a deleted user, or either book gone, is a no-op with a reason" do
            assert_equal "user 0 no longer exists", Relink.call(verdict: verdict(user_id: 0)).data[:reason]

            gone = verdict
            gone.payload["to_book_id"] = 0
            assert_equal "book 0 no longer exists", Relink.call(verdict: gone).data[:reason]
          end
        end
      end
    end
  end
end

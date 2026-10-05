require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class FindJunkTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @orphan = ::Books::Book.create!(title: "Wrongly Matched Book")
          ::Books::BookAuthor.create!(book: @orphan, author: books_authors(:king))
          @item = UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @orphan)
        end

        def approved_relink(user: @user, from: @orphan)
          ::Books::RepairVerdict.create!(kind: :relink, subject_key: "user:#{user.id}:book:#{from.id}:goodreads:1",
            decided_by: :ai, status: :approved, reviewed_at: Time.current,
            payload: {"user_id" => user.id, "from_book_id" => from.id, "to_book_id" => books_books(:got).id})
        end

        def verdict_for(book)
          ::Books::RepairVerdict.mark_provisional.find_by(subject_key: "book:#{book.id}")
        end

        test "an authorless book on no curated list is marked provisional on its own" do
          authorless = ::Books::Book.create!(title: "Nobody Wrote This")

          FindJunk.call

          verdict = verdict_for(authorless)
          assert_predicate verdict, :approved?
          assert_equal "authorless", verdict.payload["reason"]
        end

        test "an authorless book on a curated list is only proposed, so no list page loses it unasked" do
          authorless = ::Books::Book.create!(title: "Nobody Wrote This Either")
          list = lists(:books_list)
          ListItem.create!(list: list, listable: authorless, position: 99)

          FindJunk.call

          verdict = verdict_for(authorless)
          assert_predicate verdict, :proposed?
          assert_equal [list.id], verdict.payload["curated_list_ids"]
        end

        test "a book every holder is relinked away from, on no curated list, is marked provisional" do
          approved_relink

          FindJunk.call

          verdict = verdict_for(@orphan)
          assert_predicate verdict, :approved?
          assert_equal "no support after relinks", verdict.payload["reason"]
        end

        test "another user's list item or review keeps the book" do
          approved_relink
          other_list = ::Books::UserList.create!(user: users(:editor_user), name: "Shelf", list_type: :custom)
          UserListItem.create!(user_list: other_list, listable: @orphan)

          FindJunk.call

          assert_nil verdict_for(@orphan)
        end

        test "a book the relinked user's other row still names is not junk" do
          ::Identifier.create!(identifiable: @orphan, identifier_type: :books_work_goodreads_id, value: "111")
          import = ::Books::GoodreadsImport.create!(user: @user, source: :legacy_replay, status: :complete, legacy_import_id: 78)
          agreeing = ::Books::GoodreadsEdition.create!(goodreads_book_id: 111, signature: "s111", title: "Wrongly Matched Book", primary_author: "Stephen King")
          import.rows.create!(row_number: 1, goodreads_edition: agreeing)
          approved_relink

          FindJunk.call

          assert_nil verdict_for(@orphan)
        end

        test "a proposed relink is not enough" do
          approved_relink.update!(status: :proposed, reviewed_at: nil)

          FindJunk.call

          assert_nil verdict_for(@orphan)
        end

        test "finds only; flags nothing provisional" do
          ::Books::Book.create!(title: "Nobody Wrote This")
          approved_relink

          assert_no_difference(-> { ::Books::Book.where(provisional: true).count }) { FindJunk.call }
        end
      end
    end
  end
end

require "test_helper"

module Services
  module Books
    module BookSubmissions
      class BookUsesTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper
        include GoodreadsImportHelper

        setup do
          stub_review_side_effects
          @reader = users(:regular_user)
          @submission = reviewable_submission(user: @reader)
          @book = @submission.book
        end

        def uses = BookUses.call(book: @book)

        test "a book nobody else touches has no uses" do
          assert_equal [], uses
        end

        test "the submitter's own items, reviews and favorites are not uses, on whatever list they sit" do
          UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @book)
          UserListItem.create!(user_list: user_lists(:regular_user_books_favorites), listable: @book)
          Review.create!(user: @reader, reviewable: @book, rating: 4)

          assert_equal [], uses
        end

        test "a second reader with a submission on the book (even not_needed) is a submitter" do
          other = users(:editor_user)
          reviewable_submission(user: other, book: @book, review_status: :not_needed)
          list = ::Books::UserList.create!(user: other, name: "Other custom", list_type: :custom)
          UserListItem.create!(user_list: list, listable: @book)
          Review.create!(user: other, reviewable: @book, rating: 2)

          assert_equal [], uses
        end

        test "an item or a review of someone who did not submit it is a use, named separately" do
          other = users(:editor_user)
          list = ::Books::UserList.create!(user: other, name: "Other custom", list_type: :custom)
          UserListItem.create!(user_list: list, listable: @book)

          assert_equal 1, uses.size
          assert_match(/list item/, uses.first)

          Review.create!(user: other, reviewable: @book, rating: 2)
          assert_equal 2, uses.size
          assert_match(/review/, uses.last)
        end

        test "a submission whose reader was deleted does not hide anyone's use" do
          @submission.update_columns(user_id: nil)
          list = ::Books::UserList.create!(user: users(:editor_user), name: "Other custom", list_type: :custom)
          UserListItem.create!(user_list: list, listable: @book)

          assert_equal 1, uses.size
        end

        test "a curated list item is a use" do
          ListItem.create!(list: lists(:books_list), listable: @book, position: 1)

          assert_equal 1, uses.size
          assert_match(/list/, uses.first)
        end

        test "a Goodreads import row on a live import is a use, on a rejected import it is not" do
          import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :complete)
          edition = goodreads_edition(title: @book.title, book: @book, resolution: :created, resolved_at: Time.current)
          import.rows.create!(row_number: 1, goodreads_edition: edition)

          assert_equal 1, uses.size
          assert_match(/Goodreads/, uses.first)

          import.update_columns(review_status: ::Books::GoodreadsImport.review_statuses.fetch("rejected"))
          assert_equal [], uses
        end

        test "a Goodreads import record naming the book is a use" do
          import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :complete)
          import.records.create!(record: @book, action: :created)

          assert_equal 1, uses.size
        end

        test "series membership and a merge redirect are not uses" do
          series = ::Books::Series.create!(title: "A Series Of Things")
          ::Books::SeriesBook.create!(series: series, book: @book, position: 1)
          RecordRedirect.create!(item_type: "Books::Book", from_id: 999_999_001, to_id: @book.id)

          assert_equal [], uses
        end
      end
    end
  end
end

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class DeleteProvisionalTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          @user = User.create!(email: "deleter@example.com", role: :user, email_verified: false)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :complete)
          @author = ::Books::Author.create!(name: "Delete Provisional Author", provisional: true)
          @book = ::Books::Book.create!(title: "Delete Provisional Book", provisional: true)
          ::Books::BookAuthor.create!(book: @book, author: @author, position: 1)
          @import.records.create!(record: @book, action: :created)
          @import.records.create!(record: @author, action: :created)
          @edition = goodreads_edition(title: "Delete Provisional Book", book: @book, resolution: :created, resolved_at: Time.current)
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          @item = ::Books::UserList.find_by!(user: @user, list_type: :read).user_list_items.create!(listable: @book)
          @review = ::Review.create!(user: @user, reviewable: @book, rating: 3)
          @row = @import.rows.create!(row_number: 1, goodreads_edition: @edition, outcome: :applied,
            applied: {"list_item_ids" => [@item.id], "review_id" => @review.id})
        end

        test "deletes the book with this import's items and review, its orphaned author, and skips the row" do
          result = DeleteProvisional.call(import: @import, record: @book)

          assert result.data[:deleted]
          assert_not ::Books::Book.exists?(@book.id)
          assert_not ::Books::Author.exists?(@author.id)
          assert_not ::UserListItem.exists?(@item.id)
          assert_not ::Review.exists?(@review.id)
          assert_equal ["skipped", "removed by an admin", {}], [@row.reload.outcome, @row.outcome_detail, @row.applied]
          assert_nil @edition.reload.book_id
        end

        test "a book another import's rows name is kept" do
          other = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :complete)
          other.rows.create!(row_number: 1, goodreads_edition: @edition)

          result = DeleteProvisional.call(import: @import, record: @book)

          assert_not result.data[:deleted]
          assert ::Books::Book.exists?(@book.id)
          assert ::UserListItem.exists?(@item.id)
        end

        test "a book on a curated list, or on a list outside this import, is kept" do
          ::Books::UserList.find_by!(user: @user, list_type: :want_to_read).user_list_items.create!(listable: @book)

          assert_not DeleteProvisional.call(import: @import, record: @book).data[:deleted]
        end

        test "an approved book is never deleted" do
          @book.update!(provisional: false)

          assert_not DeleteProvisional.call(import: @import, record: @book).data[:deleted]
        end

        test "an author still credited on a book is kept; an uncredited one is deleted" do
          assert_not DeleteProvisional.call(import: @import, record: @author).data[:deleted]

          ::Books::BookAuthor.where(author: @author).delete_all
          assert DeleteProvisional.call(import: @import, record: @author).data[:deleted]
        end
      end
    end
  end
end

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ProvisionalReferencesTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "refs@example.com", role: :user, email_verified: false)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :complete)
          @book = ::Books::Book.create!(title: "References Book", provisional: true)
        end

        test "a book only this import uses is not used elsewhere" do
          assert_not ProvisionalReferences.book_used_elsewhere?(@book, import: @import)
        end

        test "another live import's rows are a use; a rejected import's are not" do
          edition = goodreads_edition(title: "References Book", book: @book, resolution: :created, resolved_at: Time.current)
          other = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :complete, review_status: :rejected)
          other.rows.create!(row_number: 1, goodreads_edition: edition)

          assert_not ProvisionalReferences.book_used_elsewhere?(@book, import: @import)

          other.update!(review_status: :pending)
          assert ProvisionalReferences.book_used_elsewhere?(@book, import: @import)
        end

        test "a curated list item is a use" do
          ::ListItem.create!(list: lists(:books_list), listable: @book, position: 1)

          assert ProvisionalReferences.book_used_elsewhere?(@book, import: @import)
        end

        test "another user's review is a use" do
          ::Review.create!(user: users(:regular_user), reviewable: @book, rating: 2)

          assert ProvisionalReferences.book_used_elsewhere?(@book, import: @import)
        end
      end
    end
  end
end

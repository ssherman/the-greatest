require "test_helper"

module Admin
  module Books
    class CreditsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        @edition = books_editions(:wp_maude)
        @author = books_authors(:tolstoy)
        host! Rails.application.config.domains[:books]
      end

      test "create adds a credit to a book and redirects to the book" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("@book.credits.count", 1) do
          post admin_books_book_credits_path(@book), params: {books_credit: {author_id: @author.id, role: "translator", position: 1}}
        end
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "translator", @book.credits.order(:created_at).last.role
      end

      test "create adds a credit to an edition and redirects to the edition" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("@edition.credits.count", 1) do
          post admin_books_edition_credits_path(@edition), params: {books_credit: {author_id: @author.id, role: "illustrator"}}
        end
        assert_redirected_to admin_books_edition_path(@edition)
        assert_equal "illustrator", @edition.credits.order(:created_at).last.role
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::Credit.count") do
          post admin_books_book_credits_path(@book), params: {books_credit: {author_id: @author.id, role: "editor"}}
        end
        assert_redirected_to books_root_path
      end

      test "update changes the role" do
        sign_in_as(@admin_user, stub_auth: true)
        credit = @book.credits.create!(author: @author, role: :translator)
        patch admin_books_credit_path(credit), params: {books_credit: {role: "editor", position: 2}}
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "editor", credit.reload.role
      end

      test "destroy removes the credit and redirects to its creditable" do
        sign_in_as(@admin_user, stub_auth: true)
        credit = @edition.credits.create!(author: @author, role: :narrator)
        assert_difference("::Books::Credit.count", -1) do
          delete admin_books_credit_path(credit)
        end
        assert_redirected_to admin_books_edition_path(@edition)
      end
    end
  end
end

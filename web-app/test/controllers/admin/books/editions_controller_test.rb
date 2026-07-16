require "test_helper"

module Admin
  module Books
    class EditionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        @edition = books_editions(:wp_maude)

        host! Rails.application.config.domains[:books]
      end

      # Index (nested, lazy frame)

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_book_editions_path(@book)
        assert_redirected_to books_root_path
      end

      test "index renders the book's editions frame for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_editions_path(@book)
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_book_editions_path(@book)
        assert_response :success
      end
    end
  end
end

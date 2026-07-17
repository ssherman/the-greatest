require "test_helper"

module Admin
  module Books
    class BookAuthorsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        @author = books_authors(:tolstoy)
        host! Rails.application.config.domains[:books]
      end

      test "create adds an author to the book and redirects" do
        sign_in_as(@admin_user, stub_auth: true)
        author = ::Books::Author.create!(name: "Fresh Author", kind: :person)
        assert_difference("@book.book_authors.count", 1) do
          post admin_books_book_book_authors_path(@book), params: {books_book_author: {author_id: author.id, role: "author", position: 1, credited_as: "F. Author"}}
        end
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "F. Author", @book.book_authors.order(:created_at).last.credited_as
      end

      test "create is forbidden for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::BookAuthor.count") do
          post admin_books_book_book_authors_path(@book), params: {books_book_author: {author_id: @author.id, role: "author"}}
        end
        assert_redirected_to books_root_path
      end

      test "update changes the role and position" do
        sign_in_as(@admin_user, stub_auth: true)
        ba = @book.book_authors.create!(author: ::Books::Author.create!(name: "Up Author", kind: :person), role: :author, position: 1)
        patch admin_books_book_author_path(ba), params: {books_book_author: {role: "editor", position: 3}}
        assert_redirected_to admin_books_book_path(@book)
        assert_equal "editor", ba.reload.role
        assert_equal 3, ba.position
      end

      test "destroy removes the association" do
        sign_in_as(@admin_user, stub_auth: true)
        ba = @book.book_authors.create!(author: ::Books::Author.create!(name: "Del Author", kind: :person), role: :author)
        assert_difference("::Books::BookAuthor.count", -1) do
          delete admin_books_book_author_path(ba)
        end
        assert_redirected_to admin_books_book_path(@book)
      end
    end
  end
end

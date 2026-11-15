require "test_helper"

module Admin
  module Books
    class BookAuthorsControllerTest < ActionDispatch::IntegrationTest
      setup do
        stub_workflow_dispatch
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

      test "create without position appends" do
        sign_in_as(@admin_user, stub_auth: true)
        author = ::Books::Author.create!(name: "Tail Author", kind: :person)
        max = @book.book_authors.maximum(:position)
        post admin_books_book_book_authors_path(@book), params: {books_book_author: {author_id: author.id, role: "author", position: ""}}
        assert_equal max + 1, @book.book_authors.find_by(author_id: author.id).position
      end

      test "create of an author already on the book is unprocessable" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::BookAuthor.count") do
          post admin_books_book_book_authors_path(@book, format: :turbo_stream), params: {books_book_author: {author_id: @author.id, role: "author"}}
        end
        assert_response :unprocessable_entity
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

      test "update with a blank position clears it" do
        sign_in_as(@admin_user, stub_auth: true)
        ba = @book.book_authors.create!(author: ::Books::Author.create!(name: "Clr Author", kind: :person), role: :author, position: 4)
        patch admin_books_book_author_path(ba), params: {books_book_author: {position: ""}}
        assert_redirected_to admin_books_book_path(@book)
        assert_nil ba.reload.position
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

require "test_helper"

module Admin
  module Books
    class AuthorBooksControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @author = books_authors(:king)
        host! Rails.application.config.domains[:books]
      end

      test "lists the author's books, ranked first, linking to each book's admin page" do
        RankedItem.create!(item: books_books(:clash), ranking_configuration: ranking_configurations(:books_global), rank: 7)
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_books_path(@author)
        assert_response :success
        # The frame id is the show page's contract: without it the lazy frame never fills.
        assert_select "turbo-frame#author_books_list"
        hrefs = css_select("tbody a").map { |a| a["href"] }
        assert_equal [admin_books_book_path(books_books(:clash)), admin_books_book_path(books_books(:got))], hrefs
        # Book links leave the frame; otherwise they render "Content missing".
        assert_select "tbody a[data-turbo-frame=_top]", count: 2
      end

      test "lists only this author's books" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_books_path(@author)
        assert_response :success
        assert_select "tbody a[href=?]", admin_books_book_path(books_books(:war_and_peace)), count: 0
      end

      test "renders the empty state for an author with no books" do
        @author.book_authors.delete_all
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_books_path(@author)
        assert_response :success
        assert_select "table", count: 0
        assert_select "turbo-frame#author_books_list"
      end

      test "pages the books, with page links that load" do
        AuthorBooksController::PER_PAGE.times do |i|
          book = ::Books::Book.create!(title: "Paged Book #{i}")
          ::Books::BookAuthor.create!(book: book, author: @author)
        end
        total = @author.book_authors.count
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_books_path(@author)
        assert_response :success
        assert_select "tbody tr", count: AuthorBooksController::PER_PAGE

        hrefs = css_select("nav a[href]").map { |a| a["href"] }.uniq
        assert_not_empty hrefs
        hrefs.each do |href|
          get href
          assert_response :success
        end

        get admin_books_author_books_path(@author, page: 2)
        assert_response :success
        assert_select "tbody tr", count: total - AuthorBooksController::PER_PAGE
      end

      test "redirects a signed-out visitor" do
        get admin_books_author_books_path(@author)
        assert_response :redirect
      end

      test "redirects a non-admin user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_author_books_path(@author)
        assert_response :redirect
      end

      test "returns 404 for a missing author" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_author_books_path(author_id: 0)
        assert_response :not_found
      end
    end
  end
end

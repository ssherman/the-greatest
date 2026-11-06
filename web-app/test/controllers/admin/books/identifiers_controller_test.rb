require "test_helper"

module Admin
  module Books
    class IdentifiersControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)
        host! Rails.application.config.domains[:books]
      end

      test "lists the book's identifiers" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_identifiers_path(@book)
        assert_response :success
        assert_select "table tbody tr", count: @book.identifiers.count
        # The frame id is the show page's contract: without it the lazy frame never fills.
        assert_select "turbo-frame#identifiers_list"
      end

      test "lists only this book's identifiers" do
        other = books_books(:crime_and_punishment).identifiers.first
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_identifiers_path(@book)
        assert_response :success
        assert_select "td", text: other.value, count: 0
      end

      test "renders the empty state for a book with no identifiers" do
        @book.identifiers.delete_all
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_identifiers_path(@book)
        assert_response :success
        assert_select "table", count: 0
        assert_select "turbo-frame#identifiers_list"
      end

      test "pages the identifiers, with page links that load" do
        (IdentifiersController::PER_PAGE + 1).times do |i|
          @book.identifiers.create!(identifier_type: :books_work_isbn13, value: format("97800000%05d", i), source: :open_library)
        end
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_identifiers_path(@book)
        assert_response :success
        assert_select "table tbody tr", count: IdentifiersController::PER_PAGE

        hrefs = css_select("nav a[href]").map { |a| a["href"] }.uniq
        assert_not_empty hrefs
        hrefs.each do |href|
          get href
          assert_response :success
        end

        get admin_books_book_identifiers_path(@book, page: 2)
        assert_response :success
        assert_select "table tbody tr", count: @book.identifiers.count - IdentifiersController::PER_PAGE
      end

      test "redirects a signed-out visitor" do
        get admin_books_book_identifiers_path(@book)
        assert_response :redirect
      end

      test "redirects a non-admin user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_book_identifiers_path(@book)
        assert_response :redirect
      end

      test "returns 404 for a missing book" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_book_identifiers_path(book_id: 0)
        assert_response :not_found
      end
    end
  end
end

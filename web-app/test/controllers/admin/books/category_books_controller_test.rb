require "test_helper"

module Admin
  module Books
    class CategoryBooksControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @category = categories(:books_novels_genre)
        host! Rails.application.config.domains[:books]
      end

      test "lists the category's books, ranked first, linking to each book's admin page" do
        RankedItem.create!(item: books_books(:got), ranking_configuration: ranking_configurations(:books_global), rank: 3)
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_category_books_path(@category)
        assert_response :success
        # The frame id is the show page's contract: without it the lazy frame never fills.
        assert_select "turbo-frame#category_books_list"
        hrefs = css_select("tbody a").map { |a| a["href"] }
        expected = [:got, :crime_and_punishment, :war_and_peace].map { |name| admin_books_book_path(books_books(name)) }
        assert_equal expected, hrefs
        # Book links leave the frame; otherwise they render "Content missing".
        assert_select "tbody a[data-turbo-frame=_top]", count: 3
      end

      test "lists only this category's books" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_category_books_path(@category)
        assert_response :success
        assert_select "tbody a[href=?]", admin_books_book_path(books_books(:clash)), count: 0
      end

      test "renders the empty state for a category with no books" do
        @category.category_items.delete_all
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_category_books_path(@category)
        assert_response :success
        assert_select "table", count: 0
        assert_select "turbo-frame#category_books_list"
      end

      test "pages the books, with page links that load" do
        CategoryBooksController::PER_PAGE.times do |i|
          book = ::Books::Book.create!(title: "Paged Book #{i}")
          CategoryItem.create!(category: @category, item: book)
        end
        total = @category.category_items.where(item_type: "Books::Book").count
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_category_books_path(@category)
        assert_response :success
        assert_select "tbody tr", count: CategoryBooksController::PER_PAGE

        hrefs = css_select("nav a[href]").map { |a| a["href"] }.uniq
        assert_not_empty hrefs
        hrefs.each do |href|
          get href
          assert_response :success
        end

        get admin_books_category_books_path(@category, page: 2)
        assert_response :success
        assert_select "tbody tr", count: total - CategoryBooksController::PER_PAGE
      end

      test "redirects a signed-out visitor" do
        get admin_books_category_books_path(@category)
        assert_response :redirect
      end

      test "redirects a non-admin user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_category_books_path(@category)
        assert_response :redirect
      end

      test "returns 404 for a missing category" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_category_books_path(category_id: 0)
        assert_response :not_found
      end
    end
  end
end

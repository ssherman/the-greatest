require "test_helper"

module Books
  class BooksControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      @book = books_books(:war_and_peace)
    end

    test "renders a book by slug" do
      get "/book/#{@book.slug}"
      assert_response :success
    end

    test "404s for an unknown slug" do
      get "/book/no-such-book"
      assert_response :not_found
    end

    test "does not fall back to a primary key lookup" do
      get "/book/#{@book.id}"
      assert_response :not_found
    end

    test "marks a ranked book indexable" do
      RankedItem.create!(item: @book, ranking_configuration: @rc, rank: 1, score: 100)

      get "/book/#{@book.slug}"

      assert @controller.view_assigns["indexable"]
    end

    test "marks an unranked book not indexable" do
      get "/book/#{@book.slug}"

      refute @controller.view_assigns["indexable"]
    end

    test "renders a book whose slug is purely numeric" do
      numeric = Books::Book.create!(title: "Nineteen Eighty-Four Vol 1", slug: "1984")

      get "/book/1984"

      assert_response :success
      assert_equal numeric.id, @controller.view_assigns["book"].id
    end
  end
end

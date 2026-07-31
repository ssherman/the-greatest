require "test_helper"

module Books
  class LegacyBooksControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @book = books_books(:war_and_peace)
    end

    test "redirects the legacy canonical url permanently" do
      get "/books/#{@book.id}"

      assert_response :moved_permanently
      assert_redirected_to "/book/#{@book.slug}"
    end

    test "redirects the older items url permanently" do
      get "/items/#{@book.id}"

      assert_response :moved_permanently
      assert_redirected_to "/book/#{@book.slug}"
    end

    test "drops the legacy ranking configuration segment" do
      get "/rc/52/books/#{@book.id}"

      assert_response :moved_permanently
      assert_redirected_to "/book/#{@book.slug}"
    end

    test "404s for an unknown id" do
      get "/books/99999999"
      assert_response :not_found
    end

    # The regression guard for the friendly_id slug-before-id collision.
    test "a numeric slug and the same number as an id resolve to different books" do
      target = books_books(:crime_and_punishment)
      collider = Books::Book.create!(title: "Collider Volume One", slug: target.id.to_s)

      get "/book/#{target.id}"
      assert_response :success
      assert_equal collider.id, @controller.view_assigns["book"].id

      get "/books/#{target.id}"
      assert_response :moved_permanently
      assert_redirected_to "/book/#{target.slug}"
    end
  end
end

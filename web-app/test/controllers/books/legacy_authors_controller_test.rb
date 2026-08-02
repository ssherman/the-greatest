require "test_helper"

module Books
  class LegacyAuthorsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @author = books_authors(:tolstoy)
    end

    test "redirects the legacy author url to the slug url" do
      get "/authors/#{@author.id}"

      assert_redirected_to "/author/#{@author.slug}"
      assert_response :moved_permanently
    end

    test "redirects the legacy all_books url to the slug url" do
      get "/authors/#{@author.id}/all_books"

      assert_redirected_to "/author/#{@author.slug}"
      assert_response :moved_permanently
    end

    test "redirects legacy view urls to the index" do
      get "/authors/view/condensed"

      assert_redirected_to "/authors"
      assert_response :moved_permanently
    end

    test "404s for an unknown legacy id" do
      get "/authors/999999999"

      assert_response :not_found
    end
  end
end

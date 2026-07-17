require "test_helper"

module Admin
  module Books
    class AuthorsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @author = books_authors(:tolstoy)
        host! Rails.application.config.domains[:books]
      end

      test "search redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get search_admin_books_authors_path(q: "tol")
        assert_redirected_to books_root_path
      end

      test "search returns autocomplete JSON for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::AuthorAutocomplete.expects(:call).with("tol", size: 20).returns([{id: @author.id.to_s, score: 1.0, source: {"name" => @author.name}}])
        get search_admin_books_authors_path(q: "tol")
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal @author.id, body.first["value"]
        assert_equal @author.name, body.first["text"]
      end

      test "search returns an empty array when nothing matches" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::AuthorAutocomplete.stubs(:call).returns([])
        get search_admin_books_authors_path(q: "zzz")
        assert_response :success
        assert_equal [], JSON.parse(response.body)
      end
    end
  end
end

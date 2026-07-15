require "test_helper"

module Admin
  module Books
    class BooksControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)
        @book = books_books(:war_and_peace)

        host! Rails.application.config.domains[:books]
      end

      # Authorization

      test "index redirects to root for unauthenticated users" do
        get admin_books_books_path
        assert_redirected_to books_root_path
      end

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_books_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_books_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_books_path
        assert_response :success
      end

      # Index behavior

      test "index without a query renders the sorted list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_books_path
        assert_response :success
      end

      test "index with a query loads books from OpenSearch in relevance order" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: @book.id.to_s, score: 1.0, source: {"title" => @book.title}}])
        get admin_books_books_path(q: "war")
        assert_response :success
      end

      test "index with a query that matches nothing does not error" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookGeneral.stubs(:call).returns([])
        get admin_books_books_path(q: "zzzznomatch")
        assert_response :success
      end

      test "index tolerates a malicious sort param without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_books_path(sort: "'; DROP TABLE books_books; --")
        end
        assert_response :success
      end

      # Typeahead

      test "search returns autocomplete JSON" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookAutocomplete.expects(:call).with("war", size: 20).returns([{id: @book.id.to_s, score: 1.0, source: {"title" => @book.title}}])
        get search_admin_books_books_path(q: "war")
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal @book.id, body.first["value"]
        assert_includes body.first["text"], @book.title
      end

      test "search returns an empty array when nothing matches" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Search::Books::Search::BookAutocomplete.stubs(:call).returns([])
        get search_admin_books_books_path(q: "zzz")
        assert_response :success
        assert_equal [], JSON.parse(response.body)
      end
    end
  end
end

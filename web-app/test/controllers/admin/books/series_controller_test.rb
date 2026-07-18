require "test_helper"

module Admin
  module Books
    class SeriesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @series = books_series(:asoiaf)
        host! Rails.application.config.domains[:books]
      end

      # Authorization

      test "index redirects to root for unauthenticated users" do
        get admin_books_series_index_path
        assert_redirected_to books_root_path
      end

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_series_index_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_series_index_path
        assert_response :success
      end

      # Index behavior (SQL ILIKE — no OpenSearch, no stubbing; mirrors games series tests)

      test "index without a query renders the sorted list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path
        assert_response :success
      end

      test "index with a matching query renders successfully" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path(q: "song of ice")
        assert_response :success
      end

      test "index with a non-matching query renders successfully" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_index_path(q: "zzzznomatch")
        assert_response :success
      end

      test "index tolerates a malicious query without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_series_index_path(q: "100%_off'; DROP TABLE books_series; --")
        end
        assert_response :success
      end

      test "index tolerates a malicious sort param without raising" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_series_index_path(sort: "'; DROP TABLE books_series; --")
        end
        assert_response :success
      end

      # Show

      test "show renders for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_series_path(@series)
        assert_response :success
      end

      test "show redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_series_path(@series)
        assert_redirected_to books_root_path
      end
    end
  end
end

require "test_helper"

module Admin
  module Books
    class DashboardControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)

        host! Rails.application.config.domains[:books]
      end

      test "should redirect to root for unauthenticated users" do
        get admin_books_root_path
        assert_redirected_to books_root_path
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_root_path
        assert_redirected_to books_root_path
      end

      test "should allow admin users to access dashboard" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_root_path
        assert_response :success
      end

      test "should allow editor users to access dashboard" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_books_root_path
        assert_response :success
      end

      test "should allow a books domain role to access dashboard" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_root_path
        assert_response :success
      end

      test "renders the books layout, not the music fallback" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_root_path

        assert_response :success
        assert_select "title", text: /The Greatest Books/
        assert_match %r{/assets/books-[^"]*\.css}, response.body
        assert_no_match %r{/assets/music-[^"]*\.css}, response.body
      end

      test "renders books branding with no empty domain nav section" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_root_path

        assert_response :success
        assert_select "aside[data-testid=admin-sidebar]" do
          assert_select "h1", text: "The Greatest Books"
          assert_select "summary", text: /Books/, count: 0
          assert_select "a[href=?]", admin_penalties_path
          assert_select "a[href=?]", admin_users_path
        end
      end
    end
  end
end

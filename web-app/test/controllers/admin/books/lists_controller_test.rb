require "test_helper"

module Admin
  module Books
    class ListsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        host! Rails.application.config.domains[:books]

        @list = ::Books::List.create!(name: "Test Books List", status: :approved, year_published: 2020)
      end

      test "index redirects unauthenticated users" do
        get admin_books_lists_path
        assert_redirected_to books_root_path
      end

      test "index redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_lists_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_lists_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_lists_path
        assert_response :success
      end

      test "show renders without a wizard button" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_list_path(@list)
        assert_response :success
        assert_no_match "Launch Wizard", response.body
      end

      test "list show renders for a books domain viewer without error" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_list_path(@list)
        assert_response :success
      end

      test "show renders for an auto-generated list" do
        sign_in_as(@admin_user, stub_auth: true)
        @list.update!(auto_generated_kind: :user_favorites)

        get admin_books_list_path(@list)

        assert_response :success
      end

      test "creates a list for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::List.count", 1) do
          post admin_books_lists_path, params: {books_list: {name: "New List", status: "unapproved"}}
        end
        assert_redirected_to admin_books_list_path(::Books::List.order(:id).last)
      end

      test "updates a list for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_list_path(@list), params: {books_list: {name: "Renamed"}}
        @list.reload
        assert_redirected_to admin_books_list_path(@list)
        assert_equal "Renamed", @list.name
      end

      test "destroys a list for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::List.count", -1) do
          delete admin_books_list_path(@list)
        end
        assert_redirected_to admin_books_lists_path
      end

      # The generated list owns its public URL, its RankedList row and its
      # penalties; deleting it takes all of that. The admin Delete button is
      # hidden for it, and the endpoint refuses rather than 500s.
      test "refuses to destroy an auto-generated list" do
        sign_in_as(@admin_user, stub_auth: true)
        @list.update!(auto_generated_kind: :user_favorites)

        assert_no_difference("::Books::List.count") do
          delete admin_books_list_path(@list)
        end

        assert_redirected_to admin_books_list_path(@list)
      end

      test "index filters to user submitted lists" do
        sign_in_as(@admin_user, stub_auth: true)
        submitted = ::Books::List.create!(name: "From a reader", status: :unapproved,
          submitted_at: Time.current, submitter_email: "reader@example.com")
        admin_made = ::Books::List.create!(name: "From an import", status: :unapproved)

        get admin_books_lists_path(submitted: "submitted")

        assert_response :success
        assert_match submitted.name, response.body
        assert_no_match admin_made.name, response.body
      end

      test "index filters to admin created lists" do
        sign_in_as(@admin_user, stub_auth: true)
        submitted = ::Books::List.create!(name: "From a reader", status: :unapproved,
          submitted_at: Time.current)
        admin_made = ::Books::List.create!(name: "From an import", status: :unapproved)

        get admin_books_lists_path(submitted: "admin")

        assert_response :success
        assert_match admin_made.name, response.body
        assert_no_match submitted.name, response.body
      end

      test "index shows every list when the submitted filter is absent" do
        sign_in_as(@admin_user, stub_auth: true)
        submitted = ::Books::List.create!(name: "From a reader", status: :unapproved,
          submitted_at: Time.current)
        admin_made = ::Books::List.create!(name: "From an import", status: :unapproved)

        get admin_books_lists_path

        assert_response :success
        assert_match submitted.name, response.body
        assert_match admin_made.name, response.body
      end

      test "index shows the submitter for an anonymous submission" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Books::List.create!(name: "Anon list", status: :unapproved, submitted_at: Time.current)

        get admin_books_lists_path(submitted: "submitted")

        assert_response :success
        assert_match "Anonymous", response.body
      end
    end
  end
end

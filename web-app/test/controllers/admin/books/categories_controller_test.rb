require "test_helper"

module Admin
  module Books
    class CategoriesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @category = categories(:books_fiction_genre)
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        host! Rails.application.config.domains[:books]
      end

      # Authorization

      test "index redirects to root for unauthenticated users" do
        get admin_books_categories_path
        assert_redirected_to books_root_path
      end

      test "index redirects to root for a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_categories_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_categories_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_categories_path
        assert_response :success
      end

      # Index

      test "index with a search query" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_categories_path(q: "Fiction")
        assert_response :success
      end

      test "index tolerates a sort-injection attempt" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_categories_path(sort: "'; DROP TABLE categories; --")
        end
        assert_response :success
      end

      # Show

      test "show for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_category_path(@category)
        assert_response :success
      end

      # Create

      test "creates a category for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::Category.count", 1) do
          post admin_books_categories_path, params: {
            books_category: {name: "Magical Realism", description: "Blends realism with magical elements", category_type: "genre"}
          }
        end
        assert_redirected_to admin_books_category_path(::Books::Category.last)
      end

      test "does not create a category with a blank name" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Category.count") do
          post admin_books_categories_path, params: {books_category: {name: "", category_type: "genre"}}
        end
        assert_response :unprocessable_entity
      end

      # Update

      test "updates a category for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_category_path(@category), params: {books_category: {name: "Updated Fiction"}}
        @category.reload
        assert_redirected_to admin_books_category_path(@category)
        assert_equal "Updated Fiction", @category.name
      end

      # Destroy (soft delete)

      test "soft-deletes a category for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_no_difference("::Books::Category.count") do
          delete admin_books_category_path(@category)
        end
        assert_redirected_to admin_books_categories_path
        @category.reload
        assert @category.deleted
      end

      # Search

      test "search returns JSON" do
        sign_in_as(@admin_user, stub_auth: true)
        get search_admin_books_categories_path(q: "Fic"), as: :json
        assert_response :success
      end
    end
  end
end

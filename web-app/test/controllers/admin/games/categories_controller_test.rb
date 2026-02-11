require "test_helper"

module Admin
  module Games
    class CategoriesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @category = categories(:games_action_genre)
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)

        host! Rails.application.config.domains[:games]
      end

      # Authentication/Authorization Tests

      test "should redirect index to root for unauthenticated users" do
        get admin_games_categories_path
        assert_redirected_to games_root_path
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_categories_path
        assert_redirected_to games_root_path
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_categories_path
        assert_response :success
      end

      test "should allow editor users to access index" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_games_categories_path
        assert_response :success
      end

      # Index Tests

      test "should get index without search" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_categories_path
        assert_response :success
      end

      test "should get index with search query" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_categories_path(q: "Action")
        assert_response :success
      end

      test "should handle sorting by name" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_categories_path(sort: "name")
        assert_response :success
      end

      test "should reject invalid sort parameters" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_games_categories_path(sort: "'; DROP TABLE categories; --")
        end
        assert_response :success
      end

      # Show Tests

      test "should get show for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_category_path(@category)
        assert_response :success
      end

      test "should not get show for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_category_path(@category)
        assert_redirected_to games_root_path
      end

      # Create Tests

      test "should create category for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::Category.count", 1) do
          post admin_games_categories_path, params: {
            games_category: {
              name: "RPG",
              description: "Role-playing games",
              category_type: "genre"
            }
          }
        end

        assert_redirected_to admin_games_category_path(::Games::Category.last)
      end

      test "should not create category with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Games::Category.count") do
          post admin_games_categories_path, params: {
            games_category: {
              name: "",
              category_type: "genre"
            }
          }
        end

        assert_response :unprocessable_entity
      end

      # Update Tests

      test "should update category for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_category_path(@category), params: {
          games_category: {name: "Updated Action"}
        }

        @category.reload
        assert_redirected_to admin_games_category_path(@category)
        assert_equal "Updated Action", @category.name
      end

      # Destroy Tests (Soft Delete)

      test "should soft delete category for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Games::Category.count") do
          delete admin_games_category_path(@category)
        end

        assert_redirected_to admin_games_categories_path
        @category.reload
        assert @category.deleted
      end

      test "should not soft delete category for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        delete admin_games_category_path(@category)

        assert_redirected_to games_root_path
        @category.reload
        assert_not @category.deleted
      end

      # Search Tests

      test "should return JSON search results" do
        sign_in_as(@admin_user, stub_auth: true)
        get search_admin_games_categories_path(q: "Act"), as: :json
        assert_response :success
      end
    end
  end
end

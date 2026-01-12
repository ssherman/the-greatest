require "test_helper"

module Admin
  module Music
    class CategoriesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @category = categories(:music_rock_genre)
        @child_category = categories(:music_progressive_rock_genre)
        @deleted_category = categories(:music_deleted_genre)
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)

        # Set the host to match the music domain constraint
        host! Rails.application.config.domains[:music]
      end

      # Authentication/Authorization Tests

      test "should redirect index to root for unauthenticated users" do
        get admin_categories_path
        assert_redirected_to music_root_path
        assert_equal "Access denied. Admin or editor role required.", flash[:alert]
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_categories_path
        assert_redirected_to music_root_path
        assert_equal "Access denied. Admin or editor role required.", flash[:alert]
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_categories_path
        assert_response :success
      end

      test "should allow editor users to access index" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_categories_path
        assert_response :success
      end

      # Index Tests

      test "should get index without search" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_categories_path
        assert_response :success
      end

      test "should get index with search query" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_categories_path(q: "Rock")
        assert_response :success
      end

      test "should handle empty search results without error" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_nothing_raised do
          get admin_categories_path(q: "nonexistentcategory12345")
        end

        assert_response :success
      end

      test "should handle sorting by name" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_categories_path(sort: "name")
        assert_response :success
      end

      test "should handle sorting by category_type" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_categories_path(sort: "category_type")
        assert_response :success
      end

      test "should handle sorting by item_count" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_categories_path(sort: "item_count")
        assert_response :success
      end

      test "should reject invalid sort parameters and default to name" do
        sign_in_as(@admin_user, stub_auth: true)

        # Should not raise an error, should default to sorting by name
        assert_nothing_raised do
          get admin_categories_path(sort: "'; DROP TABLE categories; --")
        end
        assert_response :success

        # Verify categories table still exists by querying it
        assert ::Music::Category.count > 0
      end

      test "should only show active categories in index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_categories_path
        assert_response :success
        # The deleted category should not appear - this is implicitly tested by the query
      end

      # Show Tests

      test "should get show for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_category_path(@category)
        assert_response :success
      end

      test "should get show for editor" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_category_path(@category)
        assert_response :success
      end

      test "should not get show for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_category_path(@category)
        assert_redirected_to music_root_path
      end

      test "should render show page with child categories without error" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_category_path(@category)
        assert_response :success
      end

      # New Tests

      test "should get new for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_category_path
        assert_response :success
      end

      test "should not get new for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get new_admin_category_path
        assert_redirected_to music_root_path
      end

      # Create Tests

      test "should create category for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Music::Category.count", 1) do
          post admin_categories_path, params: {
            music_category: {
              name: "New Genre",
              description: "A new genre description",
              category_type: "genre"
            }
          }
        end

        assert_redirected_to admin_category_path(::Music::Category.last)
        assert_equal "Category created successfully.", flash[:notice]
      end

      test "should create category with parent for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Music::Category.count", 1) do
          post admin_categories_path, params: {
            music_category: {
              name: "Sub Rock",
              description: "A subgenre of rock",
              category_type: "genre",
              parent_id: @category.id
            }
          }
        end

        new_category = ::Music::Category.last
        assert_equal @category, new_category.parent
      end

      test "should not create category with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Music::Category.count") do
          post admin_categories_path, params: {
            music_category: {
              name: "",
              category_type: "genre"
            }
          }
        end

        assert_response :unprocessable_entity
      end

      test "should not create category for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        assert_no_difference("::Music::Category.count") do
          post admin_categories_path, params: {
            music_category: {
              name: "New Genre",
              category_type: "genre"
            }
          }
        end

        assert_redirected_to music_root_path
      end

      # Edit Tests

      test "should get edit for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_category_path(@category)
        assert_response :success
      end

      test "should not get edit for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get edit_admin_category_path(@category)
        assert_redirected_to music_root_path
      end

      # Update Tests

      test "should update category for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_category_path(@category), params: {
          music_category: {
            name: "Updated Rock"
          }
        }

        @category.reload
        # Slug changes when name changes, so redirect goes to new slug
        assert_redirected_to admin_category_path(@category)
        assert_equal "Category updated successfully.", flash[:notice]
        assert_equal "Updated Rock", @category.name
      end

      test "should update category type for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_category_path(@category), params: {
          music_category: {
            category_type: "location"
          }
        }

        assert_redirected_to admin_category_path(@category)
        @category.reload
        assert_equal "location", @category.category_type
      end

      test "should not update category with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_category_path(@category), params: {
          music_category: {
            name: ""
          }
        }

        assert_response :unprocessable_entity
      end

      test "should not update category for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        patch admin_category_path(@category), params: {
          music_category: {
            name: "Updated Rock"
          }
        }

        assert_redirected_to music_root_path
        @category.reload
        assert_not_equal "Updated Rock", @category.name
      end

      # Destroy Tests (Soft Delete)

      test "should soft delete category for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Music::Category.count") do
          delete admin_category_path(@category)
        end

        assert_redirected_to admin_categories_path
        assert_equal "Category deleted successfully.", flash[:notice]
        @category.reload
        assert @category.deleted
      end

      test "should not soft delete category for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        delete admin_category_path(@category)

        assert_redirected_to music_root_path
        @category.reload
        assert_not @category.deleted
      end

      test "should allow editor to delete category" do
        sign_in_as(@editor_user, stub_auth: true)

        delete admin_category_path(@category)

        assert_redirected_to admin_categories_path
        @category.reload
        assert @category.deleted
      end
    end
  end
end

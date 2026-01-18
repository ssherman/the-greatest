require "test_helper"

# Tests that viewer-level domain users cannot perform write operations.
# This ensures proper permission enforcement - viewers should only read.
class Admin::Music::ViewerPermissionTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @contractor = users(:contractor_user)  # Has music editor role
    @category = categories(:music_rock_genre)

    # Create a viewer-only user
    @viewer = User.create!(
      email: "viewer@example.com",
      name: "Viewer User",
      role: :user,
      email_verified: true
    )
    @viewer.domain_roles.create!(domain: :music, permission_level: :viewer)

    host! Rails.application.config.domains[:music]
  end

  # Viewer should be able to read but not write

  test "viewer can access categories index" do
    sign_in_as(@viewer, stub_auth: true)
    get admin_categories_path
    assert_response :success
  end

  test "viewer can access category show" do
    sign_in_as(@viewer, stub_auth: true)
    get admin_category_path(@category)
    assert_response :success
  end

  test "viewer CANNOT create category" do
    sign_in_as(@viewer, stub_auth: true)

    assert_no_difference("Music::Category.count") do
      post admin_categories_path, params: {
        music_category: {
          name: "New Category",
          category_type: "genre"
        }
      }
    end

    # Should be denied by Pundit
    assert_redirected_to music_root_path
    assert_equal "You are not authorized to perform this action.", flash[:alert]
  end

  test "viewer CANNOT update category" do
    sign_in_as(@viewer, stub_auth: true)
    original_name = @category.name

    patch admin_category_path(@category), params: {
      music_category: {name: "Hacked Name"}
    }

    assert_redirected_to music_root_path
    assert_equal "You are not authorized to perform this action.", flash[:alert]
    @category.reload
    assert_equal original_name, @category.name
  end

  test "viewer CANNOT delete category" do
    sign_in_as(@viewer, stub_auth: true)

    delete admin_category_path(@category)

    assert_redirected_to music_root_path
    assert_equal "You are not authorized to perform this action.", flash[:alert]
    @category.reload
    assert_not @category.deleted
  end

  # Editor should be able to read and write

  test "editor can create category" do
    sign_in_as(@contractor, stub_auth: true)

    assert_difference("Music::Category.count") do
      post admin_categories_path, params: {
        music_category: {
          name: "New Category",
          category_type: "genre"
        }
      }
    end

    assert_redirected_to admin_category_path(Music::Category.last)
  end

  test "editor can update category" do
    sign_in_as(@contractor, stub_auth: true)

    patch admin_category_path(@category), params: {
      music_category: {name: "Updated Name"}
    }

    @category.reload
    assert_redirected_to admin_category_path(@category)
    assert_equal "Updated Name", @category.name
  end
end

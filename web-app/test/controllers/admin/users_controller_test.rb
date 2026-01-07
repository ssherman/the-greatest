require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @regular_user = users(:regular_user)

    host! Rails.application.config.domains[:music]
    sign_in_as(@admin, stub_auth: true)
  end

  test "should get index" do
    get admin_users_url
    assert_response :success
  end

  test "should get index with search query" do
    get admin_users_url(q: "admin")
    assert_response :success
  end

  test "should filter users by email on search" do
    get admin_users_url(q: "admin@example.com")
    assert_response :success
  end

  test "should handle empty search results without error" do
    get admin_users_url(q: "nonexistentemail@nowhere.com")
    assert_response :success
  end

  test "should get show" do
    get admin_user_url(@regular_user)
    assert_response :success
  end

  test "should get edit" do
    get edit_admin_user_url(@regular_user)
    assert_response :success
  end

  test "should update user with valid data" do
    patch admin_user_url(@regular_user), params: {
      user: {
        display_name: "Updated Display Name"
      }
    }
    assert_redirected_to admin_user_url(@regular_user)
    @regular_user.reload
    assert_equal "Updated Display Name", @regular_user.display_name
  end

  test "should update user role" do
    patch admin_user_url(@regular_user), params: {
      user: {
        role: "editor"
      }
    }
    assert_redirected_to admin_user_url(@regular_user)
    @regular_user.reload
    assert_equal "editor", @regular_user.role
  end

  test "should not update user with invalid data" do
    patch admin_user_url(@regular_user), params: {
      user: {
        email: ""
      }
    }
    assert_response :unprocessable_entity
  end

  test "should not update user with duplicate email" do
    patch admin_user_url(@regular_user), params: {
      user: {
        email: @admin.email
      }
    }
    assert_response :unprocessable_entity
  end

  test "should destroy user" do
    user_to_delete = User.create!(
      email: "todelete@example.com",
      role: :user,
      email_verified: false
    )

    assert_difference("User.count", -1) do
      delete admin_user_url(user_to_delete)
    end
    assert_redirected_to admin_users_url
  end

  test "should allow admin access" do
    get admin_users_url
    assert_response :success
  end

  test "should deny editor access" do
    sign_in_as(@editor, stub_auth: true)
    get admin_users_url
    assert_redirected_to music_root_url
  end

  test "should deny regular user access" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_users_url
    assert_redirected_to music_root_url
  end

  test "should deny unauthenticated access" do
    # Reset session to simulate unauthenticated user
    reset!
    host! Rails.application.config.domains[:music]
    get admin_users_url
    assert_redirected_to music_root_url
  end
end

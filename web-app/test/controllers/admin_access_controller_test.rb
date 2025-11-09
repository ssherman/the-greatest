require "test_helper"

class AdminAccessControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin_user = User.create!(
      email: "admin_test@example.com",
      name: "Admin Test",
      role: :admin,
      email_verified: true
    )

    @editor_user = User.create!(
      email: "editor_test@example.com",
      name: "Editor Test",
      role: :editor,
      email_verified: true
    )

    @regular_user = User.create!(
      email: "regular_test@example.com",
      name: "Regular Test",
      role: :user,
      email_verified: false
    )

    # Set host to match a domain constraint (using music domain for testing)
    host! Rails.application.config.domains[:music]
  end

  test "unauthenticated users cannot access admin area" do
    get "/admin"
    assert_redirected_to music_root_path
    assert_equal "Access denied. Admin or editor role required.", flash[:alert]
  end

  test "regular users cannot access admin area" do
    sign_in_as(@regular_user, stub_auth: true)

    get "/admin"
    assert_redirected_to music_root_path
    assert_equal "Access denied. Admin or editor role required.", flash[:alert]
  end

  test "admin users can access admin area" do
    sign_in_as(@admin_user, stub_auth: true)

    get "/admin"
    assert_response :success
  end

  test "editor users can access admin area" do
    sign_in_as(@editor_user, stub_auth: true)

    get "/admin"
    assert_response :success
  end
end

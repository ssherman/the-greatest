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
  end

  test "unauthenticated users cannot access admin area" do
    get "/admin"
    assert_response :forbidden
  end

  test "regular users cannot access admin area" do
    Services::AuthenticationService.stubs(:call).returns({success: true, user: @regular_user})
    sign_in_as(@regular_user)

    get "/admin"
    assert_response :forbidden
  end

  test "admin users can access admin area" do
    Services::AuthenticationService.stubs(:call).returns({success: true, user: @admin_user})
    sign_in_as(@admin_user)

    get "/admin"
    assert_response :redirect
    assert_redirected_to %r{/admin/}
  end

  test "editor users can access admin area" do
    Services::AuthenticationService.stubs(:call).returns({success: true, user: @editor_user})
    sign_in_as(@editor_user)

    get "/admin"
    assert_response :redirect
    assert_redirected_to %r{/admin/}
  end
end

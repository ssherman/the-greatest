require "test_helper"

class MembersControllerTest < ActionDispatch::IntegrationTest
  setup { host! Rails.application.config.domains[:books] }

  test "a member sees the members area" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get members_url

    assert_response :success
  end

  test "a comped member sees the members area" do
    sign_in_as(users(:editor_user), stub_auth: true)

    get members_url

    assert_response :success
  end

  test "a signed-in non-member is redirected to the membership page" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)

    get members_url

    assert_redirected_to membership_path
    assert_equal "That page is for members. Membership covers every site.", flash[:alert]
  end

  test "a signed-out visitor is redirected to the membership page" do
    get members_url

    assert_redirected_to membership_path
    assert_equal "Sign in to your membership to open that page.", flash[:alert]
  end

  test "a member whose comp has expired is redirected" do
    sign_in_as(users(:user_with_expired_comp), stub_auth: true)

    get members_url

    assert_redirected_to membership_path
  end

  test "the page is never cached" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get members_url

    assert_includes response.headers["Cache-Control"], "no-store"
  end
end

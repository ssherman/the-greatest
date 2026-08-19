require "test_helper"

class MembershipStateControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:books]
  end

  test "a member gets their plan and renewal date" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get membership_state_url, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["member"]
    assert_equal "monthly", body["plan"]
    assert_equal "stripe", body["source"]
    assert_equal memberships(:regular_user_monthly).current_period_end.iso8601, body["current_period_end"]
  end

  test "a comped member reports no plan and no end date" do
    sign_in_as(users(:editor_user), stub_auth: true)

    get membership_state_url, as: :json

    body = JSON.parse(response.body)
    assert_equal true, body["member"]
    assert_nil body["plan"]
    assert_equal "comped", body["source"]
    assert_nil body["current_period_end"]
  end

  test "a signed-in non-member reports member false" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)

    get membership_state_url, as: :json

    assert_equal false, JSON.parse(response.body)["member"]
  end

  test "a signed-out request is unauthorized" do
    get membership_state_url, as: :json

    assert_response :unauthorized
  end

  test "the response carries a usable csrf token" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get membership_state_url, as: :json

    assert JSON.parse(response.body)["csrf_token"].present?
  end

  test "the response is never cached" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get membership_state_url, as: :json

    assert_includes response.headers["Cache-Control"], "no-store"
  end
end

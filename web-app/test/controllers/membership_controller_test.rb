require "test_helper"

class MembershipControllerTest < ActionDispatch::IntegrationTest
  setup { host! Rails.application.config.domains[:books] }

  test "the page renders for a signed-out visitor" do
    get membership_url

    assert_response :success
  end

  test "the page renders for a member" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get membership_url

    assert_response :success
  end

  test "the page is never cached" do
    get membership_url

    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "the legacy /support url permanently redirects" do
    get "/support"

    assert_response :moved_permanently
    assert_redirected_to "/membership"
  end
end

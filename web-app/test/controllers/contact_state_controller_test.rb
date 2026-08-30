require "test_helper"

class ContactStateControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
  end

  test "returns a null email for an anonymous visitor" do
    get contact_state_path

    assert_response :success
    body = response.parsed_body
    assert_nil body["email"]
    assert body["csrf_token"].present?
  end

  test "returns the signed-in visitor's email" do
    user = users(:regular_user)
    sign_in_as(user, stub_auth: true)

    get contact_state_path

    assert_response :success
    assert_equal user.email, response.parsed_body["email"]
  end

  # The footer is on every edge-cached page. If this response were cacheable,
  # Cloudflare would hand one visitor's address to the next.
  test "is never cached" do
    get contact_state_path

    assert_match(/no-store/, response.headers["Cache-Control"])
  end
end

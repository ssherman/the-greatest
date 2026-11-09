require "test_helper"

module Oauth
  class TokensControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
    end

    test "a revoke Doorkeeper refuses is not cacheable" do
      post "/api/oauth/revoke", params: {token: "whatever"}, env: {"REMOTE_ADDR" => "203.0.113.7"}

      assert_not_equal 200, response.status
      assert_includes response.headers["Cache-Control"].to_s, "no-store"
    end
  end
end

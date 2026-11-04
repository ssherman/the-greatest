require "test_helper"

module Api
  class DispatchedRequestTest < ActiveSupport::TestCase
    def principal
      @principal ||= ::Api::Principal.new(
        user: users(:regular_user),
        token: api_tokens(:regular_user_token),
        scopes: ["books:read"],
        tier: :member
      )
    end

    test "mark sets the principal and the dispatched flag and returns the env" do
      env = Rack::MockRequest.env_for("/")

      result = ::Api::DispatchedRequest.mark(env, principal)

      assert_same env, result
      assert_same principal, env["the_greatest.api.principal"]
      assert_equal true, env["the_greatest.api.dispatched"]
    end

    test "principal and dispatched? read back what mark wrote" do
      env = ::Api::DispatchedRequest.mark(Rack::MockRequest.env_for("/"), principal)

      assert_same principal, ::Api::DispatchedRequest.principal(env)
      assert ::Api::DispatchedRequest.dispatched?(env)
    end

    test "a bare env has no principal and is not dispatched" do
      env = Rack::MockRequest.env_for("/")

      assert_nil ::Api::DispatchedRequest.principal(env)
      refute ::Api::DispatchedRequest.dispatched?(env)
    end

    test "the keys carry no HTTP_ prefix, so a client header cannot set them" do
      refute ::Api::DispatchedRequest::PRINCIPAL_KEY.start_with?("HTTP_")
      refute ::Api::DispatchedRequest::DISPATCHED_KEY.start_with?("HTTP_")
    end
  end
end

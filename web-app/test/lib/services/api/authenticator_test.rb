require "test_helper"

module Services
  module Api
    class AuthenticatorTest < ActiveSupport::TestCase
      def request_with(authorization)
        env = authorization ? {"HTTP_AUTHORIZATION" => authorization} : {}
        ActionDispatch::Request.new(Rack::MockRequest.env_for("/api/v1/books", env))
      end

      test "a member's live token yields a member principal" do
        result = Authenticator.call(request_with("Bearer #{ApiTokenSecrets::MEMBER}"))

        assert result.success?
        principal = result.data
        assert_kind_of ::Api::Principal, principal
        assert_equal users(:regular_user), principal.user
        assert_equal api_tokens(:regular_user_token), principal.token
        assert_equal ["books:read", "music:read", "games:read"], principal.scopes
        assert_equal :member, principal.tier
        assert principal.scope?("books:read")
        refute principal.scope?("books:write")
      end

      test "a service account's token yields a system principal without a membership" do
        refute users(:agent_runner_service_account).member?

        result = Authenticator.call(request_with("Bearer #{ApiTokenSecrets::SERVICE}"))

        assert result.success?
        assert_equal :system, result.data.tier
      end

      test "the scheme is case-insensitive and surrounding whitespace is tolerated" do
        assert Authenticator.call(request_with("bearer  #{ApiTokenSecrets::MEMBER} ")).success?
      end

      test "no Authorization header is :unauthenticated" do
        result = Authenticator.call(request_with(nil))

        refute result.success?
        assert_equal [:unauthenticated], result.errors
      end

      test "a non-Bearer scheme is :invalid_token" do
        result = Authenticator.call(request_with("Basic dXNlcjpwYXNz"))

        assert_equal [:invalid_token], result.errors
      end

      test "an empty bearer value is :invalid_token" do
        assert_equal [:invalid_token], Authenticator.call(request_with("Bearer ")).errors
        assert_equal [:invalid_token], Authenticator.call(request_with("Bearer")).errors
      end

      test "an unknown secret is :invalid_token" do
        assert_equal [:invalid_token], Authenticator.call(request_with("Bearer tg_#{"z" * 40}")).errors
      end

      test "an expired token is :invalid_token" do
        assert_equal [:invalid_token], Authenticator.call(request_with("Bearer #{ApiTokenSecrets::EXPIRED}")).errors
      end

      test "a person without an active membership is :membership_required" do
        result = Authenticator.call(request_with("Bearer #{ApiTokenSecrets::NON_MEMBER}"))

        assert_equal [:membership_required], result.errors
        assert_nil result.data
      end

      test "a lapsed membership turns a working token into :membership_required" do
        users(:regular_user).memberships.update_all(status: :unpaid)

        assert_equal [:membership_required], Authenticator.call(request_with("Bearer #{ApiTokenSecrets::MEMBER}")).errors
      end

      test "a successful authentication records last use" do
        token = api_tokens(:regular_user_token)
        assert_nil token.last_used_at

        Authenticator.call(request_with("Bearer #{ApiTokenSecrets::MEMBER}"))

        assert_not_nil token.reload.last_used_at
      end

      test "a failed authentication records nothing" do
        Authenticator.call(request_with("Bearer #{ApiTokenSecrets::NON_MEMBER}"))

        assert_nil api_tokens(:non_member_token).reload.last_used_at
      end
    end
  end
end

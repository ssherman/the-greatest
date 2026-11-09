require "test_helper"

module Services
  module Api
    class AuthenticatorTest < ActiveSupport::TestCase
      # The authenticator reads the site's scopes from Current.domain, which a
      # request sets in production.
      setup { Current.domain = :books }

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

      test "a dispatched request returns the env principal without a token lookup or record_use" do
        principal = Authenticator.call(request_with("Bearer #{ApiTokenSecrets::MEMBER}")).data
        env = ::Api::DispatchedRequest.mark(Rack::MockRequest.env_for("/"), principal)
        Tokens.expects(:authenticate).never
        Tokens.expects(:record_use).never

        result = Authenticator.call(ActionDispatch::Request.new(env))

        assert result.success?
        assert_same principal, result.data
      end

      test "a principal under any other env key is ignored" do
        principal = Authenticator.call(request_with("Bearer #{ApiTokenSecrets::MEMBER}")).data
        env = Rack::MockRequest.env_for("/")
        env["HTTP_THE_GREATEST_API_PRINCIPAL"] = principal

        result = Authenticator.call(ActionDispatch::Request.new(env))

        refute result.success?
        assert_equal [:unauthenticated], result.errors
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

      def mint(user, scopes)
        Services::Api::Tokens.generate(user: user, name: "mcp", scopes: scopes, expires_at: 30.days.from_now).data[:secret]
      end

      test "an admin without a membership authenticates as an admin principal" do
        admin = users(:admin_user)
        admin.memberships.destroy_all
        result = Authenticator.call(request_with("Bearer #{mint(admin, ["books:admin:merge"])}"))

        assert result.success?
        assert_equal :admin, result.data.tier
        assert_equal ["books:read", "books:admin:read", "books:admin:write", "books:admin:merge"].sort, result.data.scopes.sort
      end

      test "demotion takes effect on the next request" do
        user = users(:regular_user)
        role = DomainRole.create!(user: user, domain: :books, permission_level: :admin)
        secret = mint(user, ["books:admin:merge"])
        assert_includes Authenticator.call(request_with("Bearer #{secret}")).data.scopes, "books:admin:merge"

        role.update!(permission_level: :viewer)
        result = Authenticator.call(request_with("Bearer #{secret}"))

        assert result.success?
        assert_equal :admin, result.data.tier
        assert_equal ["books:read", "books:admin:read"], result.data.scopes
      end

      test "an admin-scoped token whose owner lost every role and membership is :membership_required" do
        admin = users(:admin_user)
        secret = mint(admin, ["books:admin:merge"])
        admin.update!(role: :user)
        admin.memberships.destroy_all

        assert_equal [:membership_required], Authenticator.call(request_with("Bearer #{secret}")).errors
      end

      def oauth_request(path, secret)
        env = {"HTTP_AUTHORIZATION" => "Bearer #{secret}"}
        ActionDispatch::Request.new(Rack::MockRequest.env_for(path, env))
      end

      def oauth_secret(connection = oauth_connections(:member_mcp), **options)
        issue_oauth_token(connection, **options).first
      end

      test "an OAuth token on /api/mcp yields an oauth member principal" do
        connection = oauth_connections(:member_mcp)
        secret = oauth_secret(connection)

        result = Authenticator.call(oauth_request("/api/mcp", secret))

        assert result.success?
        principal = result.data
        assert_equal users(:regular_user), principal.user
        assert_equal ["books:read"], principal.scopes
        assert_equal :member, principal.tier
        assert_equal "oauth", principal.token_kind
        assert_kind_of OauthAccessToken, principal.token
        assert_equal connection, principal.token.connection
      end

      test "an admin_mcp token on /api/mcp/admin yields an admin principal" do
        secret = oauth_secret(oauth_connections(:admin_mcp))

        result = Authenticator.call(oauth_request("/api/mcp/admin", secret))

        assert result.success?
        assert_equal :admin, result.data.tier
        assert_includes result.data.scopes, "books:admin:merge"
        assert_includes result.data.scopes, "books:read"
      end

      test "an admin_mcp token is :invalid_token on /api/mcp and on REST" do
        secret = oauth_secret(oauth_connections(:admin_mcp))

        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/mcp", secret)).errors
        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/v1/books", secret)).errors
      end

      test "a member_mcp token is :invalid_token on /api/mcp/admin" do
        secret = oauth_secret(oauth_connections(:member_mcp))

        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/mcp/admin", secret)).errors
      end

      test "a demoted admin's admin_mcp token is :invalid_token" do
        secret = oauth_secret(oauth_connections(:admin_mcp))
        users(:admin_user).update!(role: :user)

        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/mcp/admin", secret)).errors
      end

      test "a personal token's principal has token_kind personal" do
        result = Authenticator.call(request_with("Bearer #{ApiTokenSecrets::MEMBER}"))

        assert_equal "personal", result.data.token_kind
      end

      test "an OAuth token is :invalid_token on REST and on the admin endpoint" do
        secret = oauth_secret

        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/v1/books", secret)).errors
        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/mcp/admin", secret)).errors
      end

      test "an expired OAuth token is :invalid_token" do
        secret = oauth_secret(expires_in: 1.hour)

        travel 2.hours do
          assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/mcp", secret)).errors
        end
      end

      test "a revoked OAuth token is :invalid_token" do
        secret = oauth_secret
        OauthAccessToken.by_token(secret).revoke

        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/mcp", secret)).errors
      end

      test "an OAuth token whose connection is revoked is :invalid_token" do
        connection = oauth_connections(:member_mcp)
        secret = oauth_secret(connection)
        connection.update_columns(revoked_at: Time.current)

        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/mcp", secret)).errors
      end

      test "an OAuth token whose connection is for another resource is :invalid_token" do
        connection = oauth_connections(:member_mcp)
        secret = oauth_secret(connection)
        connection.update_columns(resource: "something-else")

        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/mcp", secret)).errors
      end

      test "an unknown bearer value on /api/mcp is :invalid_token" do
        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/mcp", "not-a-real-token")).errors
      end

      test "a lapsed membership makes an OAuth token :invalid_token, never :membership_required" do
        secret = oauth_secret
        memberships(:regular_user_monthly).update!(status: :unpaid)

        assert_equal [:invalid_token], Authenticator.call(oauth_request("/api/mcp", secret)).errors
      end

      test "a personal token whose owner lapsed is still :membership_required" do
        memberships(:regular_user_monthly).update!(status: :unpaid)

        assert_equal [:membership_required], Authenticator.call(request_with("Bearer #{ApiTokenSecrets::MEMBER}")).errors
      end

      test "first use of a refreshed OAuth token revokes the refresh token it replaced" do
        connection = oauth_connections(:member_mcp)
        _, old_refresh = issue_oauth_token(connection)
        old = OauthAccessToken.by_refresh_token(old_refresh)
        # What Doorkeeper's refresh request does: the new token carries the old one's stored refresh token.
        refreshed = OauthAccessToken.create_for(
          application: connection.application, resource_owner: connection.user,
          scopes: Doorkeeper::OAuth::Scopes.from_array(connection.scopes), expires_in: 3600,
          use_refresh_token: true, connection_id: connection.id, previous_refresh_token: old.refresh_token
        )
        assert_not_empty refreshed.previous_refresh_token
        assert_not old.reload.revoked?

        result = Authenticator.call(oauth_request("/api/mcp", refreshed.plaintext_token))

        assert result.success?
        assert_equal "", refreshed.reload.previous_refresh_token
        assert old.reload.revoked?
      end

      test "a successful OAuth authentication records the connection's last use" do
        connection = oauth_connections(:member_mcp)
        secret = oauth_secret(connection)
        assert_nil connection.last_used_at

        Authenticator.call(oauth_request("/api/mcp", secret))

        assert_not_nil connection.reload.last_used_at
      end

      test "an OAuth token still authenticates after the member's sessions are destroyed" do
        secret = oauth_secret
        users(:regular_user).sessions.destroy_all

        assert Authenticator.call(oauth_request("/api/mcp", secret)).success?
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

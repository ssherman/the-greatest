require "test_helper"

module Services
  module Oauth
    class TokenGateTest < ActiveSupport::TestCase
      setup do
        @connection = oauth_connections(:member_mcp)
        @base = ::Api::Host.base_url(:books)
      end

      def gate(**params) = TokenGate.call(params: params, domain: :books)

      def refresh_gate(refresh, **extra) = gate(grant_type: "refresh_token", refresh_token: refresh, **extra)

      def issue
        _, refresh = issue_oauth_token(@connection)
        [OauthAccessToken.by_refresh_token(refresh), refresh]
      end

      def make_grant
        OauthAccessGrant.create!(
          application: @connection.application, resource_owner_id: @connection.user_id,
          expires_in: 600, redirect_uri: "http://localhost/callback", scopes: "books:read",
          connection: @connection
        )
      end

      test "a live refresh token passes" do
        _, refresh = issue

        assert refresh_gate(refresh).success?
      end

      test "an unknown refresh token passes through for Doorkeeper to answer" do
        assert refresh_gate("not-a-real-refresh-token").success?
        assert refresh_gate(nil).success?
        assert refresh_gate(["x"]).success?
      end

      test "a parameter Doorkeeper reads as a string is refused when it is an array or a hash" do
        %i[grant_type code_verifier redirect_uri scope client_id].each do |name|
          [["x"], {"a" => "b"}].each do |value|
            params = {grant_type: "refresh_token", refresh_token: "x"}
            params[name] = value
            result = gate(**params)

            assert_not result.success?, "#{name} as #{value.class} was let through"
            assert_equal [:invalid_request], result.errors
          end
        end
      end

      test "absent or blank string parameters are not malformed" do
        assert refresh_gate("x", scope: nil, code_verifier: "").success?
      end

      test "a grant type the gate does not check passes" do
        assert gate(grant_type: "password").success?
        assert gate.success?
      end

      test "an admin connection refreshes up to 30 days after approval" do
        connection = oauth_connections(:admin_mcp)
        _, refresh = issue_oauth_token(connection)

        travel_to connection.approved_at + 29.days + 23.hours do
          assert refresh_gate(refresh).success?
        end
      end

      test "an admin refresh past 30 days is invalid_grant and leaves the connection live" do
        connection = oauth_connections(:admin_mcp)
        _, refresh = issue_oauth_token(connection)

        travel_to connection.approved_at + 30.days + 1.minute do
          result = refresh_gate(refresh)

          assert_not result.success?
          assert_equal [:invalid_grant], result.errors
        end
        assert_nil connection.reload.revoked_at
      end

      test "a member connection refreshes long after 30 days" do
        _, refresh = issue

        travel_to @connection.approved_at + 400.days do
          assert refresh_gate(refresh).success?
        end
      end

      test "a demoted admin's refresh is invalid_grant and revokes the connection" do
        connection = oauth_connections(:admin_mcp)
        _, refresh = issue_oauth_token(connection)
        connection.user.update!(role: :user)

        result = refresh_gate(refresh)

        assert_not result.success?
        assert_equal [:invalid_grant], result.errors
        assert connection.reload.revoked?
      end

      test "a revoked refresh token issued under this approval is refused and revokes the connection" do
        token, refresh = issue
        token.revoke

        result = refresh_gate(refresh)

        assert_not result.success?
        assert_equal [:invalid_grant], result.errors
        assert @connection.reload.revoked?
      end

      test "a revoked refresh token from before a re-approval is refused and leaves the new approval alone" do
        token, refresh = issue
        token.revoke
        travel 1.minute do
          @connection.update!(approved_at: Time.current)

          result = refresh_gate(refresh)

          assert_equal [:invalid_grant], result.errors
          assert_not @connection.reload.revoked?
        end
      end

      test "a refresh token on a revoked connection is refused" do
        _, refresh = issue
        @connection.update_columns(revoked_at: Time.current)

        assert_equal [:invalid_grant], refresh_gate(refresh).errors
      end

      test "a lapsed membership refuses the refresh and revokes the connection for good" do
        _, refresh = issue
        memberships(:regular_user_monthly).update!(status: :unpaid)

        assert_equal [:invalid_grant], refresh_gate(refresh).errors
        assert @connection.reload.revoked?
        assert OauthAccessToken.by_refresh_token(refresh).revoked?

        memberships(:regular_user_monthly).update!(status: :active)

        assert_equal [:invalid_grant], refresh_gate(refresh).errors
        assert @connection.reload.revoked?
      end

      test "a refresh naming another resource is invalid_target" do
        _, refresh = issue

        assert_equal [:invalid_target], refresh_gate(refresh, resource: "#{@base}/api/mcp/admin").errors
        assert_equal [:invalid_target], refresh_gate(refresh, resource: "https://other.example/api/mcp").errors
        assert_equal [:invalid_target], refresh_gate(refresh, resource: ["#{@base}/api/mcp"]).errors
        assert_not @connection.reload.revoked?
      end

      test "a refresh naming the connection's resource, or none, passes" do
        _, refresh = issue

        assert refresh_gate(refresh, resource: "#{@base}/api/mcp").success?
        assert refresh_gate(refresh, resource: "").success?
      end

      test "a code exchange naming another resource is invalid_target" do
        grant = make_grant
        code = grant.plaintext_token

        assert_equal [:invalid_target], gate(grant_type: "authorization_code", code: code, resource: "#{@base}/api/mcp/admin").errors
        assert gate(grant_type: "authorization_code", code: code, resource: "#{@base}/api/mcp").success?
        assert gate(grant_type: "authorization_code", code: code).success?
      end

      test "an unknown code passes through for Doorkeeper to answer" do
        assert gate(grant_type: "authorization_code", code: "nope", resource: "#{@base}/api/mcp/admin").success?
        assert gate(grant_type: "authorization_code").success?
      end
    end
  end
end

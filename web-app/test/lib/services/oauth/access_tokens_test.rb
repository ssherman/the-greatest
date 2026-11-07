require "test_helper"

module Services
  module Oauth
    class AccessTokensTest < ActiveSupport::TestCase
      setup do
        @connection = oauth_connections(:member_mcp)
        @mcp = ::Oauth::Resources.fetch("mcp")
        @secret, = issue_oauth_token(@connection)
      end

      test "find_live returns the token for its own resource" do
        token = AccessTokens.find_live(@secret, resource: @mcp)

        assert_kind_of OauthAccessToken, token
        assert_equal @connection, token.connection
      end

      test "find_live is nil without a resource, a secret or a match" do
        assert_nil AccessTokens.find_live(@secret, resource: nil)
        assert_nil AccessTokens.find_live(nil, resource: @mcp)
        assert_nil AccessTokens.find_live("", resource: @mcp)
        assert_nil AccessTokens.find_live("nope", resource: @mcp)
      end

      test "find_live is nil for a revoked, expired or disconnected token" do
        revoked, = issue_oauth_token(@connection)
        OauthAccessToken.by_token(revoked).revoke
        assert_nil AccessTokens.find_live(revoked, resource: @mcp)

        short, = issue_oauth_token(@connection, expires_in: 1.minute)
        travel 2.minutes do
          assert_nil AccessTokens.find_live(short, resource: @mcp)
        end

        Connections.revoke!(@connection)
        assert_nil AccessTokens.find_live(@secret, resource: @mcp)
      end

      test "find_live is nil when the connection belongs to another resource" do
        @connection.update_columns(resource: "retired")

        assert_nil AccessTokens.find_live(@secret, resource: @mcp)
      end

      test "record_use stamps the connection's last use" do
        token = AccessTokens.find_live(@secret, resource: @mcp)
        assert_nil @connection.last_used_at

        AccessTokens.record_use(token)

        assert_not_nil @connection.reload.last_used_at
      end
    end
  end
end

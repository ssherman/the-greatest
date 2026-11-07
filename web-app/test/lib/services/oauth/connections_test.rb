require "test_helper"

module Services
  module Oauth
    class ConnectionsTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @app = oauth_applications(:claude_code)
        @other_app = oauth_applications(:claude_ai)
      end

      def approve(application: @app, scopes: ["books:read"])
        Connections.approve(user: @user, application: application, resource_key: "mcp", scopes: scopes)
      end

      test "approving creates a connection" do
        connection = nil
        assert_difference "OauthConnection.count", 1 do
          result = approve(application: @other_app)
          assert result.success?
          connection = result.data
        end

        assert_equal [@user, @other_app, "mcp", ["books:read"]],
          [connection.user, connection.application, connection.resource, connection.scopes]
        assert_not_nil connection.approved_at
        assert_nil connection.revoked_at
      end

      test "approving twice keeps one row" do
        assert_no_difference "OauthConnection.count" do
          approve
          approve
        end
      end

      test "a second approval revokes the tokens and grants issued under the first and resets approved_at" do
        connection = oauth_connections(:member_mcp)
        issue_oauth_token(connection)
        grant = OauthAccessGrant.create!(
          application: @app, resource_owner_id: @user.id, connection_id: connection.id,
          token: "grant-secret", expires_in: 600, redirect_uri: "http://localhost/callback"
        )
        old_approved_at = connection.approved_at

        result = approve(scopes: ["books:read"])

        assert result.success?
        assert_equal connection, result.data
        assert_operator result.data.approved_at, :>, old_approved_at
        assert OauthAccessToken.where(connection_id: connection.id).all?(&:revoked?)
        assert grant.reload.revoked?
      end

      test "approving a revoked connection clears revoked_at and updates the scopes" do
        connection = oauth_connections(:member_mcp)
        Connections.revoke!(connection)
        assert connection.reload.revoked?

        result = approve(scopes: ["books:read", "books:write"])

        assert_not result.data.revoked?
        assert_nil connection.reload.revoked_at
        assert_equal ["books:read", "books:write"], connection.scopes
      end

      test "a re-approval's tokens are not the revoked ones" do
        connection = oauth_connections(:member_mcp)
        issue_oauth_token(connection)
        approve
        access, _refresh = issue_oauth_token(connection)

        token = OauthAccessToken.by_token(access)
        assert_not token.revoked?
      end

      test "a double-clicked Approve that loses the insert race retries once" do
        existing = approve(application: @other_app).data
        # The first lookup misses (the other request had not committed yet), so
        # the insert hits the unique index; the retry sees the committed row.
        stale = OauthConnection.new(user: @user, application: @other_app, resource: "mcp")
        OauthConnection.stubs(:find_or_initialize_by).returns(stale).then.returns(existing)

        result = nil
        assert_no_difference "OauthConnection.count" do
          result = approve(application: @other_app, scopes: ["books:read"])
        end

        assert result.success?
        assert_equal existing, result.data
      end

      test "revoke! revokes the connection's tokens and grants and leaves another connection's alone" do
        mine = oauth_connections(:member_mcp)
        other = approve(application: @other_app).data
        mine_access, = issue_oauth_token(mine)
        other_access, = issue_oauth_token(other)
        grant = OauthAccessGrant.create!(
          application: @app, resource_owner_id: @user.id, connection_id: mine.id,
          token: "mine-grant", expires_in: 600, redirect_uri: "http://localhost/callback"
        )
        stamp = Time.zone.parse("2026-11-06 12:00:00")

        Connections.revoke!(mine, at: stamp)

        assert_equal stamp, mine.reload.revoked_at
        assert_equal stamp, OauthAccessToken.by_token(mine_access).revoked_at
        assert_equal stamp, grant.reload.revoked_at
        assert_nil other.reload.revoked_at
        assert_not OauthAccessToken.by_token(other_access).revoked?
      end

      test "revoke! keeps an earlier revocation time" do
        connection = oauth_connections(:member_mcp)
        access, = issue_oauth_token(connection)
        earlier = 2.days.ago.change(usec: 0)
        OauthAccessToken.by_token(access).update!(revoked_at: earlier)

        Connections.revoke!(connection)

        assert_equal earlier, OauthAccessToken.by_token(access).revoked_at
      end

      test "record_use writes last_used_at at most once per five minutes" do
        connection = oauth_connections(:member_mcp)
        freeze_time do
          Connections.record_use(connection)
          assert_equal Time.current, connection.reload.last_used_at

          travel 2.minutes
          Connections.record_use(connection)
          assert_equal 2.minutes.ago, connection.reload.last_used_at

          travel 4.minutes
          Connections.record_use(connection)
          assert_equal Time.current, connection.reload.last_used_at
        end
      end
    end
  end
end

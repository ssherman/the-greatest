require "test_helper"

module Services
  module Oauth
    class PrunerTest < ActiveSupport::TestCase
      setup do
        @now = Time.zone.local(2026, 11, 9, 12)
        @connection = oauth_connections(:member_mcp)
        @connection.update_columns(approved_at: @now - 10.days)
      end

      def prune = Pruner.call(now: @now)

      def make_app(created_at)
        OauthApplication.create!(name: "App", redirect_uri: "http://localhost/cb", scopes: "", confidential: false).tap do |app|
          app.update_columns(created_at: created_at)
        end
      end

      def token_for(connection, created_at:, revoked: false)
        _, refresh = issue_oauth_token(connection)
        token = OauthAccessToken.by_refresh_token(refresh)
        token.update_columns(created_at: created_at, revoked_at: (revoked ? created_at + 1.minute : nil))
        [token, refresh]
      end

      def make_grant(created_at)
        OauthAccessGrant.create!(
          application: @connection.application, resource_owner_id: @connection.user_id,
          expires_in: 600, redirect_uri: "http://localhost/callback", scopes: "books:read",
          connection: @connection
        ).tap { |grant| grant.update_columns(created_at: created_at) }
      end

      test "deletes an unused client older than the lifetime and keeps a younger one" do
        old = make_app(@now - 31.days)
        young = make_app(@now - 29.days)

        result = prune

        assert result.success?
        assert_not OauthApplication.exists?(old.id)
        assert OauthApplication.exists?(young.id)
        assert_equal 1, result.data[:applications]
      end

      test "keeps an old client that has a connection, even a revoked one" do
        app = make_app(@now - 90.days)
        @connection.update_columns(oauth_application_id: app.id, revoked_at: @now - 1.day)

        prune

        assert OauthApplication.exists?(app.id)
        assert OauthConnection.exists?(@connection.id)
      end

      test "deletes grants older than the retention and keeps recent ones" do
        old = make_grant(@now - 2.days)
        recent = make_grant(@now - 5.minutes)

        result = prune

        assert_not OauthAccessGrant.exists?(old.id)
        assert OauthAccessGrant.exists?(recent.id)
        assert_equal 1, result.data[:grants]
      end

      test "deletes every token of a revoked connection" do
        live, = token_for(@connection, created_at: @now - 1.day)
        revoked, = token_for(@connection, created_at: @now - 2.days, revoked: true)
        @connection.update_columns(revoked_at: @now - 1.hour)

        result = prune

        assert_not OauthAccessToken.exists?(live.id)
        assert_not OauthAccessToken.exists?(revoked.id)
        assert_equal 2, result.data[:tokens]
      end

      test "deletes tokens created before a live connection's approved_at" do
        stale, = token_for(@connection, created_at: @now - 11.days)
        stale_revoked, = token_for(@connection, created_at: @now - 12.days, revoked: true)

        prune

        assert_not OauthAccessToken.exists?(stale.id)
        assert_not OauthAccessToken.exists?(stale_revoked.id)
      end

      test "keeps a revoked token created after approved_at on a live connection, so reuse still revokes" do
        token, refresh = token_for(@connection, created_at: @now - 5.days, revoked: true)

        prune

        assert OauthAccessToken.exists?(token.id)
        result = TokenGate.call(params: {grant_type: "refresh_token", refresh_token: refresh}, domain: :books)
        assert_not result.success?
        assert_equal [:invalid_grant], result.errors
        assert @connection.reload.revoked?
      end

      test "keeps live unrevoked tokens, expired access part included" do
        token, = token_for(@connection, created_at: @now - 5.days)
        token.update_columns(expires_in: 60)

        result = prune

        assert OauthAccessToken.exists?(token.id)
        assert_equal 0, result.data[:tokens]
      end
    end
  end
end

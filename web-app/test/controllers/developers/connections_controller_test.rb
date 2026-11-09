require "test_helper"

module Developers
  class ConnectionsControllerTest < ActionDispatch::IntegrationTest
    TURBO = {"Accept" => "text/vnd.turbo-stream.html, text/html"}.freeze

    setup { host! Rails.application.config.domains[:books].to_s.split(",").first }

    def token_for(connection)
      OauthAccessToken.create!(application: connection.application, connection: connection,
        resource_owner_id: connection.user_id, scopes: "books:read", expires_in: 3600)
    end

    test "a member revokes their connection and every token under it" do
      connection = oauth_connections(:member_mcp)
      token = token_for(connection)
      sign_in_as(users(:regular_user), stub_auth: true)

      delete developers_connection_path(connection), headers: TURBO

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert connection.reload.revoked?
      assert token.reload.revoked?
      assert_select "turbo-stream[action=replace][target=developers_connections]", 1
      assert_select "turbo-stream[target=developers_new_token]", 0
    end

    test "a lapsed member can revoke their connection" do
      user = users(:user_with_expired_membership)
      connection = OauthConnection.create!(user: user, application: oauth_applications(:claude_ai), resource: "mcp",
        scopes: ["books:read"], approved_at: 2.days.ago)
      sign_in_as(user, stub_auth: true)

      delete developers_connection_path(connection), headers: TURBO

      assert_response :success
      assert connection.reload.revoked?
    end

    test "another user's connection is a 404 and stays live" do
      sign_in_as(users(:regular_user), stub_auth: true)

      delete developers_connection_path(oauth_connections(:admin_mcp)), headers: TURBO

      assert_response :not_found
      assert_not oauth_connections(:admin_mcp).reload.revoked?
    end

    test "an already-revoked connection is a 404 and keeps its revoked_at" do
      connection = oauth_connections(:member_mcp)
      connection.update_columns(revoked_at: 2.days.ago)
      sign_in_as(users(:regular_user), stub_auth: true)

      assert_no_changes -> { connection.reload.revoked_at } do
        delete developers_connection_path(connection), headers: TURBO
      end
      assert_response :not_found
    end

    test "a connection whose resource left the registry can still be revoked" do
      oauth_connections(:member_mcp).update_column(:resource, "retired")
      sign_in_as(users(:regular_user), stub_auth: true)

      delete developers_connection_path(oauth_connections(:member_mcp)), headers: TURBO

      assert_response :success
      assert oauth_connections(:member_mcp).reload.revoked?
    end

    test "a signed-out visitor is redirected to the membership page" do
      delete developers_connection_path(oauth_connections(:member_mcp)), headers: TURBO

      assert_redirected_to membership_path
      assert_not oauth_connections(:member_mcp).reload.revoked?
    end

    test "the response is never cached" do
      sign_in_as(users(:regular_user), stub_auth: true)

      delete developers_connection_path(oauth_connections(:member_mcp)), headers: TURBO

      assert_includes response.headers["Cache-Control"], "no-store"
    end
  end
end

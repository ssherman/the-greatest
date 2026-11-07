require "test_helper"

module Oauth
  # The whole sign-in as a client sees it: register, send the member to the
  # authorize page, Approve, then exchange, refresh and revoke at the token
  # endpoint. Every request is real; nothing in Doorkeeper is stubbed.
  class FlowTest < ActionDispatch::IntegrationTest
    include McpRpcHelpers

    BOOKS_HOST = "dev-new.thegreatestbooks.org"
    CALLBACK = "https://claude.ai/api/mcp/auth_callback"
    STATE = "flow-state-123"
    VERIFIER = "v" * 64
    CHALLENGE = Base64.urlsafe_encode64(Digest::SHA256.digest(VERIFIER), padding: false)
    RESOURCE_METADATA = "https://#{BOOKS_HOST}/.well-known/oauth-protected-resource/api/mcp".freeze

    setup do
      host! BOOKS_HOST
      @member = users(:regular_user)
      @client_id = register_client
    end

    # --- helpers -------------------------------------------------------------

    def register_client(name: "Flow test client")
      post "/api/oauth/register", params: {client_name: name, redirect_uris: [CALLBACK]}.to_json,
        headers: {"Content-Type" => "application/json"}
      assert_response :created
      response.parsed_body.fetch("client_id")
    end

    def sign_in
      sign_in_as(@member, stub_auth: true)
    end

    # Approve through the real authorize page and return the code.
    def approve(client_id: @client_id, **overrides)
      sign_in
      params = {
        client_id: client_id, redirect_uri: CALLBACK, response_type: "code", state: STATE,
        scope: "books:read", code_challenge: CHALLENGE, code_challenge_method: "S256"
      }.merge(overrides)
      get "/oauth/authorize", params: params
      assert_response :success
      post "/oauth/authorize", params: params
      assert_response :redirect
      query = Rack::Utils.parse_query(URI.parse(response.location).query)
      assert_equal STATE, query["state"]
      query.fetch("code")
    end

    def token_request(**params)
      post "/api/oauth/token", params: params.compact
    end

    def exchange(code, verifier: VERIFIER, client_id: @client_id, **extra)
      token_request(grant_type: "authorization_code", code: code, client_id: client_id,
        redirect_uri: CALLBACK, code_verifier: verifier, **extra)
    end

    def refresh(refresh_token, client_id: @client_id, **extra)
      token_request(grant_type: "refresh_token", refresh_token: refresh_token, client_id: client_id, **extra)
    end

    # Approve, exchange, and return the token response body.
    def obtain_tokens(**approve_options)
      exchange(approve(**approve_options))
      assert_response :success
      response.parsed_body
    end

    def assert_oauth_error(status, error)
      assert_response status
      assert_equal error, response.parsed_body["error"]
      assert_includes response.headers["Cache-Control"], "no-store"
    end

    def assert_mcp_works(access_token)
      rpc("tools/list", token: access_token)
      assert_response :success
    end

    def assert_mcp_refused(access_token)
      rpc("tools/list", token: access_token)
      assert_response :unauthorized
      assert_equal %(Bearer error="invalid_token", resource_metadata="#{RESOURCE_METADATA}", scope="books:read"),
        response.headers["WWW-Authenticate"]
    end

    def connection = OauthConnection.find_by!(user: @member, application: OauthApplication.find_by!(uid: @client_id))

    # --- exchange ------------------------------------------------------------

    test "the code and the right verifier give tokens that work on /api/mcp" do
      exchange(approve)

      assert_response :success
      assert_includes response.headers["Cache-Control"], "no-store"
      body = response.parsed_body
      assert body["access_token"].present?
      assert body["refresh_token"].present?
      assert_equal "Bearer", body["token_type"]
      assert_equal 3600, body["expires_in"]
      assert_equal "books:read", body["scope"]
      assert_mcp_works(body["access_token"])
    end

    test "an OAuth token can call a real tool, dispatched in-process to the REST API" do
      access = obtain_tokens["access_token"]

      call_tool("get_book", {slug: books_books(:war_and_peace).slug}, token: access)

      assert_response :success
      assert_equal false, json.dig("result", "isError")
      assert_equal "war-and-peace", tool_text.dig("data", "slug")

      call_tool("list_books", {limit: 5}, token: access)
      assert_equal false, json.dig("result", "isError")
    end

    test "a wrong verifier is invalid_grant" do
      exchange(approve, verifier: "w" * 64)

      assert_oauth_error :bad_request, "invalid_grant"
    end

    test "a missing verifier is invalid_request" do
      exchange(approve, verifier: nil)

      assert_oauth_error :bad_request, "invalid_request"
    end

    test "a code works once" do
      code = approve
      exchange(code)
      assert_response :success

      exchange(code)

      assert_oauth_error :bad_request, "invalid_grant"
    end

    test "a code is bound to the client it was issued to" do
      code = approve
      other = register_client(name: "Another client")

      exchange(code, client_id: other)

      assert_oauth_error :bad_request, "invalid_grant"
    end

    test "naming the admin endpoint as the resource is invalid_target, the MCP endpoint succeeds" do
      code = approve

      exchange(code, resource: "https://#{BOOKS_HOST}/api/mcp/admin")
      assert_oauth_error :bad_request, "invalid_target"

      exchange(code, resource: "https://#{BOOKS_HOST}/api/mcp")
      assert_response :success
    end

    # --- refresh and rotation -----------------------------------------------

    test "a refresh without scope keeps the original scopes" do
      tokens = obtain_tokens

      refresh(tokens["refresh_token"])

      assert_response :success
      assert_equal "books:read", response.parsed_body["scope"]
      assert_not_equal tokens["access_token"], response.parsed_body["access_token"]
      assert_mcp_works(response.parsed_body["access_token"])
    end

    test "a refresh naming another resource is invalid_target" do
      tokens = obtain_tokens

      refresh(tokens["refresh_token"], resource: "https://#{BOOKS_HOST}/api/mcp/admin")

      assert_oauth_error :bad_request, "invalid_target"
    end

    test "the old refresh token works until the new access token is used, then reuse revokes the connection" do
      first = obtain_tokens
      refresh(first["refresh_token"])
      assert_response :success
      second = response.parsed_body

      # Not yet used: the first refresh token still works (a client that lost
      # the response retries safely).
      refresh(first["refresh_token"])
      assert_response :success
      retried = response.parsed_body

      assert_mcp_works(second["access_token"])

      refresh(first["refresh_token"])
      assert_oauth_error :bad_request, "invalid_grant"
      assert connection.revoked?

      assert_mcp_refused(second["access_token"])
      assert_mcp_refused(retried["access_token"])
      refresh(second["refresh_token"])
      assert_oauth_error :bad_request, "invalid_grant"
    end

    test "two refreshes with the same refresh token both succeed" do
      tokens = obtain_tokens

      refresh(tokens["refresh_token"])
      assert_response :success
      refresh(tokens["refresh_token"])
      assert_response :success
    end

    test "refreshing with another client's id is invalid_grant" do
      tokens = obtain_tokens
      other = register_client(name: "Another client")

      refresh(tokens["refresh_token"], client_id: other)
      assert_oauth_error :bad_request, "invalid_grant"

      token_request(grant_type: "refresh_token", refresh_token: tokens["refresh_token"])
      assert_oauth_error :bad_request, "invalid_grant"
    end

    test "a refresh token that does not exist is invalid_grant" do
      refresh("made-up-refresh-token")

      assert_oauth_error :bad_request, "invalid_grant"
    end

    # --- re-approval ---------------------------------------------------------

    test "a refresh token from before a re-approval is refused and the new approval keeps working" do
      first = obtain_tokens
      refresh(first["refresh_token"])
      second = response.parsed_body
      assert_mcp_works(second["access_token"])

      travel 1.minute do
        fresh = obtain_tokens
        assert_not connection.revoked?

        # Everything issued under the first approval ended with the second.
        assert_mcp_refused(first["access_token"])
        assert_mcp_refused(second["access_token"])

        refresh(first["refresh_token"])
        assert_oauth_error :bad_request, "invalid_grant"
        refresh(second["refresh_token"])
        assert_oauth_error :bad_request, "invalid_grant"

        assert_not connection.revoked?
        assert_mcp_works(fresh["access_token"])
        refresh(fresh["refresh_token"])
        assert_response :success
      end
    end

    # --- lapse ---------------------------------------------------------------

    test "a lapsed membership ends the access token, the refresh, and stays ended after renewal" do
      tokens = obtain_tokens
      memberships(:regular_user_monthly).update!(status: :unpaid)

      assert_mcp_refused(tokens["access_token"])

      refresh(tokens["refresh_token"])
      assert_oauth_error :bad_request, "invalid_grant"
      assert connection.revoked?

      memberships(:regular_user_monthly).update!(status: :active)

      refresh(tokens["refresh_token"])
      assert_oauth_error :bad_request, "invalid_grant"
      assert_mcp_refused(tokens["access_token"])
    end

    # --- revoke --------------------------------------------------------------

    test "revoking with the client's own id ends the access token" do
      tokens = obtain_tokens

      post "/api/oauth/revoke", params: {token: tokens["access_token"], client_id: @client_id}

      assert_response :success
      assert_mcp_refused(tokens["access_token"])
    end

    test "revoking with another client's id is forbidden and revokes nothing" do
      tokens = obtain_tokens
      other = register_client(name: "Another client")

      post "/api/oauth/revoke", params: {token: tokens["access_token"], client_id: other}

      assert_response :forbidden
      assert_mcp_works(tokens["access_token"])
    end

    test "revoking with no client_id is forbidden" do
      tokens = obtain_tokens

      post "/api/oauth/revoke", params: {token: tokens["access_token"]}

      assert_response :forbidden
      assert_mcp_works(tokens["access_token"])
    end

    test "revoking a token that does not exist is a 200" do
      post "/api/oauth/revoke", params: {token: "nope", client_id: @client_id}

      assert_response :success
    end

    # --- rate limit ----------------------------------------------------------

    test "the 31st token request in a minute from one address is a 429, and from a connector range it is not" do
      30.times do
        token_request(grant_type: "refresh_token", refresh_token: "x", client_id: @client_id)
        assert_response :bad_request
      end

      token_request(grant_type: "refresh_token", refresh_token: "x", client_id: @client_id)
      assert_response :too_many_requests
      assert response.headers["Retry-After"].present?
      assert_includes response.headers["Cache-Control"], "no-store"

      post "/api/oauth/revoke", params: {token: "x", client_id: @client_id}
      assert_response :too_many_requests

      40.times do
        post "/api/oauth/token", params: {grant_type: "refresh_token", refresh_token: "x", client_id: @client_id},
          env: {"REMOTE_ADDR" => "160.79.104.9"}
        assert_response :bad_request
      end
    end

    # --- sign-out ------------------------------------------------------------

    test "signing out of the site does not end the connection" do
      tokens = obtain_tokens

      post "/auth/sign_out"

      assert_mcp_works(tokens["access_token"])
      refresh(tokens["refresh_token"])
      assert_response :success
    end
  end
end

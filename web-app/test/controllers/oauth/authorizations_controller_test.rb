require "test_helper"

module Oauth
  class AuthorizationsControllerTest < ActionDispatch::IntegrationTest
    BOOKS_HOST = "dev-new.thegreatestbooks.org"
    STATE = "state-from-the-client-123"
    VERIFIER = "a" * 64
    CHALLENGE = Base64.urlsafe_encode64(Digest::SHA256.digest(VERIFIER), padding: false)
    CLAUDE_URI = "https://claude.ai/api/mcp/auth_callback"

    setup do
      host! BOOKS_HOST
      @claude_ai = oauth_applications(:claude_ai)
      @claude_code = oauth_applications(:claude_code)
      @member = users(:regular_user)
      @non_member = users(:user_with_expired_membership)
    end

    def authorize_params(application: @claude_ai, redirect_uri: CLAUDE_URI, **overrides)
      {
        client_id: application.uid,
        redirect_uri: redirect_uri,
        response_type: "code",
        state: STATE,
        scope: "books:read",
        code_challenge: CHALLENGE,
        code_challenge_method: "S256"
      }.merge(overrides).compact
    end

    def redirect_query
      Rack::Utils.parse_query(URI.parse(response.location).query)
    end

    def assert_redirected_to_client(base, error: nil)
      assert_response :redirect
      assert response.location.start_with?(base), "expected a redirect to #{base}, got #{response.location}"
      assert_equal STATE, redirect_query["state"]
      if error
        assert_equal error, redirect_query["error"]
        assert_nil redirect_query["code"]
      else
        assert redirect_query["code"].present?
        assert_nil redirect_query["error"]
      end
    end

    # D16: the response either carries no CSP, or its form-action lets the form
    # post end on the client's origin. Turning CSP on later without that fails here.
    def assert_form_action_allows(redirect_uri)
      header = response.headers["Content-Security-Policy"]
      return if header.blank?

      directive = header.split(";").map(&:strip).find { |part| part.start_with?("form-action") }
      origin = URI.parse(redirect_uri).then { |uri| "#{uri.scheme}://#{uri.host}" }
      assert directive, "CSP is set but has no form-action directive"
      assert(directive.split.any? { |source| source == "*" || source.start_with?(origin) },
        "CSP form-action #{directive.inspect} does not allow #{origin}")
    end

    # --- client validation -------------------------------------------------

    test "an unknown client_id is refused without a redirect, signed out or in" do
      get "/oauth/authorize", params: authorize_params(client_id: "nope")
      assert_response :unauthorized

      sign_in_as(@member, stub_auth: true)
      get "/oauth/authorize", params: authorize_params(client_id: "nope")
      assert_response :unauthorized
    end

    test "an unregistered redirect_uri is refused without a redirect, signed out or in" do
      get "/oauth/authorize", params: authorize_params(redirect_uri: "https://evil.example/callback")
      assert_response :bad_request

      sign_in_as(@member, stub_auth: true)
      get "/oauth/authorize", params: authorize_params(redirect_uri: "https://evil.example/callback")
      assert_response :bad_request
    end

    test "a missing redirect_uri is refused without a redirect" do
      sign_in_as(@member, stub_auth: true)
      get "/oauth/authorize", params: authorize_params(redirect_uri: nil)
      assert_response :bad_request
    end

    test "Deny and Approve refuse an unregistered redirect_uri too" do
      sign_in_as(@member, stub_auth: true)

      delete "/oauth/authorize", params: authorize_params(redirect_uri: "https://evil.example/callback")
      assert_response :bad_request

      assert_no_difference -> { OauthAccessGrant.count } do
        post "/oauth/authorize", params: authorize_params(redirect_uri: "https://evil.example/callback")
      end
      assert_response :bad_request
    end

    # --- signed out ---------------------------------------------------------

    test "a signed-out visitor gets the sign-in prompt, never cached" do
      get "/oauth/authorize", params: authorize_params

      assert_response :success
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_select "[data-testid=oauth-redirect-host]", text: "claude.ai"
      assert_select "[data-testid=oauth-signed-out]"
    end

    test "a signed-out visitor who sent no scope still gets the sign-in prompt" do
      get "/oauth/authorize", params: authorize_params(scope: nil)

      assert_response :success
      assert_select "[data-testid=oauth-signed-out]"
    end

    test "a signed-out POST gets no code" do
      assert_no_difference -> { OauthAccessGrant.count } do
        post "/oauth/authorize", params: authorize_params
      end
      assert_response :unauthorized
    end

    test "the same request comes back intact after signing in" do
      get "/oauth/authorize", params: authorize_params
      assert_response :success

      sign_in_as(@member, stub_auth: true)
      get "/oauth/authorize", params: authorize_params

      assert_response :success
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_select "[data-testid=oauth-approve]"
      assert_select "form input[name=state][value=?]", STATE
      assert_select "form input[name=code_challenge][value=?]", CHALLENGE
      assert_select "form input[name=redirect_uri][value=?]", CLAUDE_URI
    end

    # --- the approval screen ------------------------------------------------

    test "a member sees the approval screen" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params

      assert_response :success
      assert_select "[data-testid=oauth-approve]"
      assert_select "[data-testid=oauth-deny]"
      assert_select "[data-testid=oauth-redirect-host]", text: "claude.ai"
      assert_select "form[data-turbo=false]", minimum: 2
      assert_equal 0, OauthAccessGrant.count
    end

    test "the approval screen cannot be framed by another site" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params

      assert_includes %w[SAMEORIGIN DENY], response.headers["X-Frame-Options"]
    end

    test "the client's own name is escaped, never rendered as markup" do
      @claude_ai.update_columns(name: "<img src=x onerror=alert(1)>")
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params

      assert_response :success
      assert_select "img[src=x]", count: 0
    end

    test "a loopback redirect shows the port the client is actually listening on" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(application: @claude_code, redirect_uri: "http://localhost:61000/callback")

      assert_response :success
      assert_select "[data-testid=oauth-redirect-host]", text: "localhost:61000"
    end

    test "an authorize request with no scope shows the approval screen and approves books:read" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(scope: nil)
      assert_response :success
      assert_select "[data-testid=oauth-approve]"

      post "/oauth/authorize", params: authorize_params(scope: nil)
      assert_redirected_to_client(CLAUDE_URI)
      grant = OauthAccessGrant.order(:id).last
      assert_equal ["books:read"], grant.scopes.to_a
    end

    test "a member who asks only for offline_access sees the approval screen and is granted books:read" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(scope: "offline_access")
      assert_response :success
      assert_select "[data-testid=oauth-approve]"

      post "/oauth/authorize", params: authorize_params(scope: "offline_access")
      assert_redirected_to_client(CLAUDE_URI)
      assert_equal ["books:read"], OauthAccessGrant.order(:id).last.scopes.to_a
    end

    # --- ineligible ---------------------------------------------------------

    test "a signed-in non-member gets the ineligible page and Return sends access_denied" do
      sign_in_as(@non_member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params
      assert_response :success
      assert_select "[data-testid=oauth-approve]", count: 0
      assert_select "[data-testid=oauth-ineligible]"

      delete "/oauth/authorize", params: authorize_params
      assert_redirected_to_client(CLAUDE_URI, error: "access_denied")
    end

    test "a non-member who asked only for offline_access still gets the ineligible page" do
      sign_in_as(@non_member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(scope: "offline_access")

      assert_response :success
      assert_select "[data-testid=oauth-approve]", count: 0
      assert_select "[data-testid=oauth-ineligible]"
    end

    test "a non-member who sent no scope is told about membership, not given an error redirect" do
      sign_in_as(@non_member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(scope: nil)

      assert_response :success
      assert_select "[data-testid=oauth-ineligible]"
    end

    test "a non-member's forged POST gets no code and creates no connection" do
      sign_in_as(@non_member, stub_auth: true)

      assert_no_difference ["OauthAccessGrant.count", "OauthConnection.count"] do
        post "/oauth/authorize", params: authorize_params(
          scope: "books:read books:admin:merge", connection_id: oauth_connections(:member_mcp).id,
          resource_key: "mcp_admin", approved_at: "2000-01-01"
        )
      end

      assert_response :forbidden
      assert response.location.nil?
    end

    # --- requests Doorkeeper refuses ----------------------------------------

    test "code_challenge_method=plain redirects with an error" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(code_challenge_method: "plain")

      assert_redirected_to_client(CLAUDE_URI, error: "invalid_code_challenge_method")
    end

    test "no code_challenge redirects with an error" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(code_challenge: nil, code_challenge_method: nil)

      assert_redirected_to_client(CLAUDE_URI, error: "invalid_request")
    end

    test "an unknown scope redirects with invalid_scope" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(scope: "nonsense:everything")

      assert_redirected_to_client(CLAUDE_URI, error: "invalid_scope")
    end

    test "a request Doorkeeper refuses cannot be approved by POST" do
      sign_in_as(@member, stub_auth: true)

      assert_no_difference ["OauthAccessGrant.count", "OauthConnection.count"] do
        post "/oauth/authorize", params: authorize_params(code_challenge_method: "plain")
      end
      assert_redirected_to_client(CLAUDE_URI, error: "invalid_code_challenge_method")
    end

    test "a resource this server does not know redirects with invalid_target" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(resource: "https://other.example/api/mcp")
      assert_redirected_to_client(CLAUDE_URI, error: "invalid_target")

      assert_no_difference -> { OauthAccessGrant.count } do
        post "/oauth/authorize", params: authorize_params(resource: "https://other.example/api/mcp")
      end
      assert_redirected_to_client(CLAUDE_URI, error: "invalid_target")
    end

    test "the admin endpoint is not a resource in this increment" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(resource: "https://#{BOOKS_HOST}/api/mcp/admin")
      assert_redirected_to_client(CLAUDE_URI, error: "invalid_target")
    end

    test "a non-string resource is refused rather than guessed at" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize?#{authorize_params.to_query}&resource[]=x"
      assert_redirected_to_client(CLAUDE_URI, error: "invalid_target")
    end

    test "the canonical resource URL is accepted" do
      sign_in_as(@member, stub_auth: true)

      get "/oauth/authorize", params: authorize_params(resource: "#{Api::Host.base_url}/api/mcp")

      assert_response :success
      assert_select "[data-testid=oauth-approve]"
    end

    # --- Approve -------------------------------------------------------------

    test "Approve redirects to the client with a code and the same state" do
      sign_in_as(@member, stub_auth: true)

      assert_difference -> { OauthConnection.count }, 1 do
        post "/oauth/authorize", params: authorize_params
      end

      assert_redirected_to_client(CLAUDE_URI)
      connection = OauthConnection.find_by!(user: @member, application: @claude_ai)
      assert_equal "mcp", connection.resource
      assert_equal ["books:read"], connection.scopes
      grant = OauthAccessGrant.order(:id).last
      assert_equal connection.id, grant.connection_id
      assert_equal @member.id, grant.resource_owner_id
      assert_equal CHALLENGE, grant.code_challenge
      assert_equal "S256", grant.code_challenge_method
      assert_equal ["books:read"], grant.scopes.to_a
    end

    test "Approve accepts a loopback redirect on a different port than the registered one" do
      sign_in_as(@member, stub_auth: true)
      callback = "http://localhost:61000/callback"

      post "/oauth/authorize", params: authorize_params(application: @claude_code, redirect_uri: callback)

      assert_redirected_to_client(callback)
      assert_equal callback, OauthAccessGrant.order(:id).last.redirect_uri
    end

    test "a re-approval whose code cannot be issued leaves the earlier approval and its tokens alone" do
      sign_in_as(@member, stub_auth: true)
      connection = oauth_connections(:member_mcp)
      access, = issue_oauth_token(connection)
      approved_at = connection.approved_at
      OauthAccessGrant.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(OauthAccessGrant.new))

      begin
        post "/oauth/authorize", params: authorize_params(application: @claude_code, redirect_uri: "http://localhost:61000/callback")
      rescue ActiveRecord::RecordInvalid
        # Raised or rescued into an error page, depending on show_exceptions;
        # either way no code went out and the transaction rolled back.
      end

      assert_nil(response&.location&.then { |location| Rack::Utils.parse_query(URI.parse(location).query)["code"] })
      assert_not OauthAccessToken.by_token(access).revoked?
      assert_equal approved_at, connection.reload.approved_at
    end

    test "the Approve response lets a form post end on the client's origin" do
      sign_in_as(@member, stub_auth: true)

      post "/oauth/authorize", params: authorize_params

      assert_response :redirect
      assert_form_action_allows(CLAUDE_URI)
    end

    test "attributes the server owns cannot be set from the request" do
      sign_in_as(users(:editor_user), stub_auth: true)
      others = oauth_connections(:member_mcp)
      forged = {connection_id: others.id, approved_at: "2000-01-01", resource_key: "mcp_admin"}

      get "/oauth/authorize", params: authorize_params(application: @claude_code, redirect_uri: "http://localhost:61000/callback", **forged)
      assert_response :success

      assert_difference -> { OauthConnection.count }, 1 do
        post "/oauth/authorize", params: authorize_params(
          application: @claude_code, redirect_uri: "http://localhost:61000/callback",
          scope: "books:read books:admin:merge", **forged
        )
      end

      connection = OauthConnection.find_by!(user: users(:editor_user), application: @claude_code)
      grant = OauthAccessGrant.order(:id).last
      assert_not_equal others.id, grant.connection_id
      assert_equal connection.id, grant.connection_id
      assert_equal "mcp", connection.resource
      assert_in_delta Time.current, connection.approved_at, 1.minute
      assert_equal ["books:read"], connection.scopes
      assert_equal ["books:read"], grant.scopes.to_a
      assert_nil others.reload.revoked_at
    end

    test "a forged scope the member cannot hold gets no code" do
      sign_in_as(@member, stub_auth: true)

      assert_no_difference ["OauthAccessGrant.count", "OauthConnection.count"] do
        post "/oauth/authorize", params: authorize_params(scope: "books:admin:merge")
      end

      assert_response :forbidden
    end

    test "Approve needs the CSRF token" do
      sign_in_as(@member, stub_auth: true)
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      assert_no_difference -> { OauthAccessGrant.count } do
        post "/oauth/authorize", params: authorize_params
      end
      assert_response :unprocessable_content
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    # --- Deny ----------------------------------------------------------------

    test "Deny redirects with access_denied and the same state and creates nothing" do
      sign_in_as(@member, stub_auth: true)

      assert_no_difference ["OauthAccessGrant.count", "OauthConnection.count"] do
        delete "/oauth/authorize", params: authorize_params
      end

      assert_redirected_to_client(CLAUDE_URI, error: "access_denied")
    end
  end
end

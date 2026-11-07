require "test_helper"

module Oauth
  class RegistrationsControllerTest < ActionDispatch::IntegrationTest
    BOOKS_HOST = "dev-new.thegreatestbooks.org"
    LOOPBACK_URI = "http://localhost:33418/callback"
    CLAUDE_URI = "https://claude.ai/api/mcp/auth_callback"

    setup do
      host! BOOKS_HOST
    end

    def register(body = nil, env: {"REMOTE_ADDR" => "203.0.113.7"}, **fields)
      body = fields if body.nil?
      body = body.to_json unless body.is_a?(String)
      post "/api/oauth/register", params: body, headers: {"CONTENT_TYPE" => "application/json"}, env: env
    end

    def json
      JSON.parse(response.body)
    end

    def assert_registration_error(error)
      assert_response :bad_request
      assert_equal error, json["error"]
      assert json["error_description"].present?
    end

    test "registers a public client for a loopback redirect URI" do
      assert_difference -> { OauthApplication.count }, 1 do
        register(redirect_uris: [LOOPBACK_URI], client_name: "Claude Code")
      end

      assert_response :created
      application = OauthApplication.find_by!(uid: json["client_id"])
      assert_nil application.secret
      assert_equal false, application.confidential
      assert_equal "Claude Code", application.name
      assert_equal LOOPBACK_URI, application.redirect_uri
      assert_equal "", application.scopes.to_s

      assert_equal application.created_at.to_i, json["client_id_issued_at"]
      assert_equal "Claude Code", json["client_name"]
      assert_equal [LOOPBACK_URI], json["redirect_uris"]
      assert_equal %w[authorization_code refresh_token], json["grant_types"]
      assert_equal ["code"], json["response_types"]
      assert_equal "none", json["token_endpoint_auth_method"]
      refute json.key?("client_secret")
    end

    test "joins several redirect URIs with newlines" do
      register(redirect_uris: [LOOPBACK_URI, CLAUDE_URI])

      assert_response :created
      assert_equal "#{LOOPBACK_URI}\n#{CLAUDE_URI}", OauthApplication.find_by!(uid: json["client_id"]).redirect_uri
    end

    test "registers the claude.ai https redirect URI" do
      register(redirect_uris: [CLAUDE_URI])

      assert_response :created
      assert_equal [CLAUDE_URI], json["redirect_uris"]
    end

    test "defaults the client name" do
      register(redirect_uris: [LOOPBACK_URI])

      assert_response :created
      assert_equal "MCP client", json["client_name"]
      assert_equal "MCP client", OauthApplication.find_by!(uid: json["client_id"]).name
    end

    test "accepts explicit values that match what is supported and ignores other fields" do
      register(
        redirect_uris: [LOOPBACK_URI],
        token_endpoint_auth_method: "none",
        grant_types: ["authorization_code"],
        response_types: ["code"],
        client_uri: "https://example.com"
      )

      assert_response :created
    end

    test "rejects redirect URIs that are not allowed" do
      [
        "http://example.com/cb",
        "cursor://x",
        "https://claude.ai/cb#f",
        "https://user:pw@claude.ai/cb",
        "https://claude.ai/#{"a" * 2_000}"
      ].each do |uri|
        assert_no_difference -> { OauthApplication.count } do
          register(redirect_uris: [uri])
        end
        assert_registration_error "invalid_redirect_uri"
      end
    end

    test "rejects an empty, missing, oversized or non-string redirect_uris" do
      [
        {redirect_uris: []},
        {},
        {redirect_uris: "https://claude.ai/cb"},
        {redirect_uris: [LOOPBACK_URI, 5]},
        {redirect_uris: Array.new(11) { |i| "https://claude.ai/cb#{i}" }}
      ].each do |body|
        register(body)
        assert_registration_error "invalid_redirect_uri"
      end
    end

    test "accepts exactly ten redirect URIs" do
      register(redirect_uris: Array.new(10) { |i| "https://claude.ai/cb#{i}" })

      assert_response :created
    end

    test "rejects client metadata this server does not support" do
      [
        {token_endpoint_auth_method: "client_secret_basic"},
        {grant_types: ["client_credentials"]},
        {grant_types: ["authorization_code", "implicit"]},
        {grant_types: "authorization_code"},
        {response_types: ["token"]},
        {client_name: "x" * 101},
        {client_name: 5}
      ].each do |extra|
        assert_no_difference -> { OauthApplication.count } do
          register({redirect_uris: [LOOPBACK_URI]}.merge(extra))
        end
        assert_registration_error "invalid_client_metadata"
      end
    end

    test "accepts a 100-character client name" do
      register(redirect_uris: [LOOPBACK_URI], client_name: "x" * 100)

      assert_response :created
    end

    test "rejects a body that is not a JSON object" do
      ["[]", '"x"', "{not json", "", "null"].each do |body|
        register(body)
        assert_registration_error "invalid_client_metadata"
      end
    end

    test "the eleventh request in a minute from one address is a 429" do
      freeze_time do
        10.times { register(redirect_uris: [LOOPBACK_URI]) }
        assert_response :created

        register(redirect_uris: [LOOPBACK_URI])

        assert_response :too_many_requests
        assert response.headers["Retry-After"].present?
        assert_equal 10, OauthApplication.where(name: "MCP client").count
      end
    end

    test "invalid requests count against the limit too" do
      freeze_time do
        10.times { register("{not json") }

        register(redirect_uris: [LOOPBACK_URI])

        assert_response :too_many_requests
      end
    end

    test "another address is not limited by the first" do
      freeze_time do
        11.times { register({redirect_uris: [LOOPBACK_URI]}) }
        assert_response :too_many_requests

        register({redirect_uris: [LOOPBACK_URI]}, env: {"REMOTE_ADDR" => "203.0.113.8"})

        assert_response :created
      end
    end

    test "a connector address shares a larger budget" do
      freeze_time do
        connector = {"REMOTE_ADDR" => "160.79.104.9"}
        11.times { register({redirect_uris: [LOOPBACK_URI]}, env: connector) }

        assert_response :created
      end
    end

    test "every response is uncacheable" do
      register(redirect_uris: [LOOPBACK_URI])
      assert_includes response.headers["Cache-Control"], "no-store"

      register("{not json")
      assert_includes response.headers["Cache-Control"], "no-store"

      freeze_time do
        10.times { register("{}") }
        assert_response :too_many_requests
        assert_includes response.headers["Cache-Control"], "no-store"
      end
    end
  end
end

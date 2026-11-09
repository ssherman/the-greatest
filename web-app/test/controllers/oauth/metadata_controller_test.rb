require "test_helper"

module Oauth
  class MetadataControllerTest < ActionDispatch::IntegrationTest
    BOOKS_HOST = "dev-new.thegreatestbooks.org"

    AUTHORIZATION_SERVER_KEYS = %w[
      issuer authorization_endpoint token_endpoint registration_endpoint revocation_endpoint
      response_types_supported grant_types_supported code_challenge_methods_supported
      token_endpoint_auth_methods_supported scopes_supported
    ].freeze

    setup do
      host! BOOKS_HOST
      @base = ::Api::Host.base_url(:books)
    end

    def protected_resource_document
      {
        "resource" => @base + "/api/mcp",
        "authorization_servers" => [@base],
        "scopes_supported" => ["books:read"],
        "bearer_methods_supported" => ["header"]
      }
    end

    # Rails emits the directives as "max-age=3600, public"; the order is not
    # significant, the set is.
    def assert_cacheable_for_an_hour
      directives = response.headers["Cache-Control"].split(",").map(&:strip)
      assert_equal ["max-age=3600", "public"], directives.sort
    end

    test "authorization server metadata has exactly the advertised keys and values" do
      get "/.well-known/oauth-authorization-server"

      assert_response :success
      body = response.parsed_body
      assert_equal AUTHORIZATION_SERVER_KEYS.sort, body.keys.sort
      assert_equal @base, body["issuer"]
      assert_equal @base + "/oauth/authorize", body["authorization_endpoint"]
      assert_equal @base + "/api/oauth/token", body["token_endpoint"]
      assert_equal @base + "/api/oauth/register", body["registration_endpoint"]
      assert_equal @base + "/api/oauth/revoke", body["revocation_endpoint"]
      assert_equal ["code"], body["response_types_supported"]
      assert_equal ["authorization_code", "refresh_token"], body["grant_types_supported"]
      assert_equal ["S256"], body["code_challenge_methods_supported"]
      assert_equal ["none"], body["token_endpoint_auth_methods_supported"]
      assert_equal ["books:read", "books:admin:read", "books:admin:write", "books:admin:merge", "offline_access"], body["scopes_supported"]
    end

    test "authorization server metadata is public JSON cacheable for an hour" do
      get "/.well-known/oauth-authorization-server"

      assert_equal "application/json", response.media_type
      assert_cacheable_for_an_hour
      assert_nil response.headers["Set-Cookie"]
    end

    test "protected resource metadata for the mcp resource" do
      get "/.well-known/oauth-protected-resource/api/mcp"

      assert_response :success
      assert_equal protected_resource_document, response.parsed_body
      assert_equal "application/json", response.media_type
      assert_cacheable_for_an_hour
      assert_nil response.headers["Set-Cookie"]
    end

    test "the root protected resource document is the same document" do
      get "/.well-known/oauth-protected-resource"

      assert_response :success
      assert_equal protected_resource_document, response.parsed_body
      assert_cacheable_for_an_hour
    end

    test "the admin endpoint has no protected resource document" do
      get "/.well-known/oauth-protected-resource/api/mcp/admin"

      assert_response :not_found
    end

    test "the music and games hosts serve no discovery documents" do
      %w[dev.thegreatestmusic.org dev.thegreatest.games].each do |hostname|
        host! hostname

        get "/.well-known/oauth-authorization-server"
        assert_response :not_found, hostname

        get "/.well-known/oauth-protected-resource/api/mcp"
        assert_response :not_found, hostname

        get "/.well-known/oauth-protected-resource"
        assert_response :not_found, hostname
      end
    end
  end
end

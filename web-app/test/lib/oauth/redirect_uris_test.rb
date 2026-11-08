require "test_helper"

module Oauth
  class RedirectUrisTest < ActiveSupport::TestCase
    def matches?(requested, registered)
      Doorkeeper::OAuth::Helpers::URIChecker.matches?(requested, registered)
    end

    test "the port is ignored for loopback hosts" do
      assert matches?("http://localhost:53122/callback", "http://localhost/callback")
      assert matches?("http://127.0.0.1:53122/callback", "http://127.0.0.1/callback")
      assert matches?("http://[::1]:53122/callback", "http://[::1]/callback")
    end

    test "the path still has to match on loopback" do
      assert_not matches?("http://localhost:5/other", "http://localhost/callback")
    end

    test "a different host never matches a registered https URI" do
      assert_not matches?("https://evil.example/api/mcp/auth_callback", "https://claude.ai/api/mcp/auth_callback")
      assert matches?("https://claude.ai/api/mcp/auth_callback", "https://claude.ai/api/mcp/auth_callback")
    end

    test "loopback_host? accepts only localhost, 127.0.0.1 and [::1]" do
      assert ::Oauth::RedirectUris.loopback_host?("localhost")
      assert ::Oauth::RedirectUris.loopback_host?("LocalHost")
      assert ::Oauth::RedirectUris.loopback_host?("127.0.0.1")
      assert ::Oauth::RedirectUris.loopback_host?("[::1]")
      assert_not ::Oauth::RedirectUris.loopback_host?("127.0.0.2")
      assert_not ::Oauth::RedirectUris.loopback_host?("localhost.evil.example")
      assert_not ::Oauth::RedirectUris.loopback_host?("example.com")
      assert_not ::Oauth::RedirectUris.loopback_host?(nil)
    end

    test "loopback? needs http and a loopback host" do
      assert ::Oauth::RedirectUris.loopback?("http://localhost:3000/cb")
      assert ::Oauth::RedirectUris.loopback?("http://[::1]:3000/cb")
      assert_not ::Oauth::RedirectUris.loopback?("https://localhost/cb")
      assert_not ::Oauth::RedirectUris.loopback?("http://example.com/cb")
      assert_not ::Oauth::RedirectUris.loopback?("not a uri")
    end

    test "valid_registration? accepts https and loopback http, nothing with a fragment or userinfo" do
      assert ::Oauth::RedirectUris.valid_registration?("https://claude.ai/api/mcp/auth_callback")
      assert ::Oauth::RedirectUris.valid_registration?("http://localhost:8080/callback")
      assert ::Oauth::RedirectUris.valid_registration?("http://127.0.0.1/callback")
      assert ::Oauth::RedirectUris.valid_registration?("http://[::1]/callback")
      assert_not ::Oauth::RedirectUris.valid_registration?("http://example.com/callback")
      assert_not ::Oauth::RedirectUris.valid_registration?("https://claude.ai/cb#frag")
      assert_not ::Oauth::RedirectUris.valid_registration?("https://user:pw@claude.ai/cb")
      assert_not ::Oauth::RedirectUris.valid_registration?("myapp://callback")
      assert_not ::Oauth::RedirectUris.valid_registration?("https:///nohost")
      assert_not ::Oauth::RedirectUris.valid_registration?("")
      assert_not ::Oauth::RedirectUris.valid_registration?(nil)
    end

    test "the application model takes a loopback http redirect and refuses other http ones" do
      assert OauthApplication.new(name: "c", redirect_uri: "http://localhost/callback", confidential: false).valid?
      assert_not OauthApplication.new(name: "c", redirect_uri: "http://example.com/cb", confidential: false).valid?
    end
  end
end

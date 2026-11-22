require "test_helper"

# The Firebase ID token is posted to /auth/sign_in as {jwt: idToken}
# (firebase_auth_service.js). It is a bearer credential, replayable for up to
# an hour, and Rails logs request parameters at info in production. "jwt"
# matches none of the other partial patterns, so it needs its own entry.
class FilterParameterLoggingTest < ActiveSupport::TestCase
  def filter
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  test "the sign-in token is filtered at the top level" do
    assert_equal "[FILTERED]", filter.filter("jwt" => "eyJhbGciOi.secret.sig")["jwt"]
  end

  test "the sign-in token is filtered inside the wrapped JSON params" do
    filtered = filter.filter("auth" => {"jwt" => "eyJhbGciOi.secret.sig"})

    assert_equal "[FILTERED]", filtered.dig("auth", "jwt")
  end

  test "the PKCE code verifier is filtered" do
    assert_equal "[FILTERED]", filter.filter("code_verifier" => "v" * 64)["code_verifier"]
  end

  test "a fetch_page url is filtered, at the top level and inside an MCP tool call" do
    url = "https://example.com/report.pdf?X-Amz-Signature=abc&token=xyz"

    assert_equal "[FILTERED]", filter.filter("url" => url)["url"]
    assert_equal "[FILTERED]", filter.filter("fetch_page" => {"url" => url})["fetch_page"]["url"]
    mcp = {"params" => {"name" => "fetch_page", "arguments" => {"url" => url}}}
    assert_equal "[FILTERED]", filter.filter(mcp).dig("params", "arguments", "url")
  end

  test "only the exact url key is filtered, so other url-ish params stay legible" do
    filtered = filter.filter("source_url" => "https://a.example/x", "api_url" => "https://b.example/y")

    assert_equal ["https://a.example/x", "https://b.example/y"], filtered.values_at("source_url", "api_url")
  end
end

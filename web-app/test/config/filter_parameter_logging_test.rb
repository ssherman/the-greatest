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
end

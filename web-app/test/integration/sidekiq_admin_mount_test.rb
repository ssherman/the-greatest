require "test_helper"

# Only the refusal paths are exercised here: Rack::Auth::Basic answers 401
# before Sidekiq::Web runs, so these need no Redis. The accept path is covered
# by SidekiqWebAuthTest.
class SidekiqAdminMountTest < ActionDispatch::IntegrationTest
  def with_env(vars)
    saved = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def basic(username, password)
    {"HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password)}
  end

  test "empty credentials are refused when the variables are unset" do
    with_env("SIDEKIQ_ADMIN_USERNAME" => nil, "SIDEKIQ_ADMIN_PASSWORD" => nil) do
      get "/sidekiq-admin", headers: basic("", "")
    end

    assert_response :unauthorized
  end

  test "wrong credentials are refused when the variables are set" do
    with_env("SIDEKIQ_ADMIN_USERNAME" => "admin", "SIDEKIQ_ADMIN_PASSWORD" => "s3cret") do
      get "/sidekiq-admin", headers: basic("admin", "wrong")
    end

    assert_response :unauthorized
  end
end

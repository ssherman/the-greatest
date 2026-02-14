# frozen_string_literal: true

require "test_helper"

class Games::Igdb::ConfigurationTest < ActiveSupport::TestCase
  def setup
    @original_client_id = ENV["TWITCH_API_CLIENT_ID"]
    @original_client_secret = ENV["TWITCH_API_CLIENT_SECRET"]
    @original_api_url = ENV["IGDB_API_URL"]
    @original_auth_url = ENV["TWITCH_AUTH_URL"]

    ENV["TWITCH_API_CLIENT_ID"] = "test_client_id"
    ENV["TWITCH_API_CLIENT_SECRET"] = "test_client_secret"
  end

  def teardown
    ENV["TWITCH_API_CLIENT_ID"] = @original_client_id
    ENV["TWITCH_API_CLIENT_SECRET"] = @original_client_secret
    ENV["IGDB_API_URL"] = @original_api_url
    ENV["TWITCH_AUTH_URL"] = @original_auth_url
  end

  test "reads client_id and client_secret from env" do
    config = Games::Igdb::Configuration.new

    assert_equal "test_client_id", config.client_id
    assert_equal "test_client_secret", config.client_secret
  end

  test "uses default values when optional env vars are not set" do
    ENV.delete("IGDB_API_URL")
    ENV.delete("TWITCH_AUTH_URL")
    config = Games::Igdb::Configuration.new

    assert_equal "https://api.igdb.com/v4", config.api_base_url
    assert_equal "https://id.twitch.tv/oauth2/token", config.auth_url
    assert_equal 30, config.timeout
    assert_equal 10, config.open_timeout
    assert_equal "The Greatest Games App/1.0", config.user_agent
    assert_equal 3, config.max_retries
    assert_equal Rails.logger, config.logger
  end

  test "uses custom IGDB_API_URL when set" do
    ENV["IGDB_API_URL"] = "http://localhost:8080"
    config = Games::Igdb::Configuration.new

    assert_equal "http://localhost:8080", config.api_base_url
  end

  test "uses custom TWITCH_AUTH_URL when set" do
    ENV["TWITCH_AUTH_URL"] = "http://localhost:9090/token"
    config = Games::Igdb::Configuration.new

    assert_equal "http://localhost:9090/token", config.auth_url
  end

  test "raises ConfigurationError when client_id is blank" do
    ENV["TWITCH_API_CLIENT_ID"] = ""

    error = assert_raises(Games::Igdb::Exceptions::ConfigurationError) do
      Games::Igdb::Configuration.new
    end
    assert_match(/TWITCH_API_CLIENT_ID/, error.message)
  end

  test "raises ConfigurationError when client_id is nil" do
    ENV.delete("TWITCH_API_CLIENT_ID")

    assert_raises(Games::Igdb::Exceptions::ConfigurationError) do
      Games::Igdb::Configuration.new
    end
  end

  test "raises ConfigurationError when client_secret is blank" do
    ENV["TWITCH_API_CLIENT_SECRET"] = ""

    assert_raises(Games::Igdb::Exceptions::ConfigurationError) do
      Games::Igdb::Configuration.new
    end
  end

  test "raises ConfigurationError for invalid API URL" do
    ENV["IGDB_API_URL"] = "not-a-url"

    assert_raises(Games::Igdb::Exceptions::ConfigurationError) do
      Games::Igdb::Configuration.new
    end
  end

  test "allows modification of configuration values" do
    config = Games::Igdb::Configuration.new

    config.timeout = 60
    config.user_agent = "Custom Agent"
    config.max_retries = 5

    assert_equal 60, config.timeout
    assert_equal "Custom Agent", config.user_agent
    assert_equal 5, config.max_retries
  end
end

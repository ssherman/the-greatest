# frozen_string_literal: true

require "test_helper"

class Music::Musicbrainz::ConfigurationTest < ActiveSupport::TestCase
  def setup
    @original_env = ENV["MUSICBRAINZ_URL"]
  end

  def teardown
    ENV["MUSICBRAINZ_URL"] = @original_env
  end

  test "uses default URL when MUSICBRAINZ_URL is not set" do
    ENV.delete("MUSICBRAINZ_URL")
    config = Music::Musicbrainz::Configuration.new

    assert_equal "https://musicbrainz.org", config.base_url
    assert_equal "https://musicbrainz.org/ws/2", config.api_url
  end

  test "uses environment variable when MUSICBRAINZ_URL is set" do
    ENV["MUSICBRAINZ_URL"] = "http://localhost:5000"
    config = Music::Musicbrainz::Configuration.new

    assert_equal "http://localhost:5000", config.base_url
    assert_equal "http://localhost:5000/ws/2", config.api_url
  end

  test "sets default values for all configuration options" do
    config = Music::Musicbrainz::Configuration.new

    assert_equal "The Greatest Music App/1.0", config.user_agent
    assert_equal 30, config.timeout
    assert_equal 10, config.open_timeout
    assert_equal Rails.logger, config.logger
  end

  test "raises error for blank MUSICBRAINZ_URL" do
    ENV["MUSICBRAINZ_URL"] = ""

    assert_raises(ArgumentError, "MUSICBRAINZ_URL cannot be blank") do
      Music::Musicbrainz::Configuration.new
    end
  end

  test "raises error for invalid MUSICBRAINZ_URL" do
    ENV["MUSICBRAINZ_URL"] = "not-a-url"

    assert_raises(ArgumentError, "MUSICBRAINZ_URL must be a valid URL") do
      Music::Musicbrainz::Configuration.new
    end
  end

  test "allows modification of configuration values" do
    config = Music::Musicbrainz::Configuration.new

    config.timeout = 60
    config.user_agent = "Custom Agent"

    assert_equal 60, config.timeout
    assert_equal "Custom Agent", config.user_agent
  end
end

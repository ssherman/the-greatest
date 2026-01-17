# frozen_string_literal: true

require "test_helper"

module Cloudflare
  class ConfigurationTest < ActiveSupport::TestCase
    setup do
      @original_env = ENV.to_hash
    end

    teardown do
      ENV.clear
      ENV.update(@original_env)
    end

    test "initializes successfully with valid API token" do
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test_token"

      config = Configuration.new

      assert_equal "test_token", config.api_token
      assert_equal 30, config.timeout
      assert_equal 10, config.open_timeout
    end

    test "raises ConfigurationError when API token is missing" do
      ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")

      error = assert_raises(Cloudflare::Exceptions::ConfigurationError) do
        Configuration.new
      end

      assert_match(/CLOUDFLARE_CACHE_PURGE_TOKEN/, error.message)
    end

    test "raises ConfigurationError when API token is blank" do
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = ""

      assert_raises(Cloudflare::Exceptions::ConfigurationError) do
        Configuration.new
      end
    end

    test "api_url returns Cloudflare API base URL" do
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test_token"

      config = Configuration.new

      assert_equal "https://api.cloudflare.com/client/v4", config.api_url
    end

    test "zone_id returns zone ID for valid domain" do
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test_token"
      ENV["MUSIC_CLOUDFLARE_ZONE_ID"] = "music_zone_123"

      config = Configuration.new

      assert_equal "music_zone_123", config.zone_id(:music)
    end

    test "zone_id returns nil when zone ID is not configured" do
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test_token"
      ENV.delete("MUSIC_CLOUDFLARE_ZONE_ID")

      config = Configuration.new

      assert_nil config.zone_id(:music)
    end

    test "zone_id raises ZoneNotFoundError for invalid domain" do
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test_token"

      config = Configuration.new

      assert_raises(Cloudflare::Exceptions::ZoneNotFoundError) do
        config.zone_id(:invalid_domain)
      end
    end

    test "configured_zones returns hash of domains with zone IDs" do
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test_token"
      ENV["MUSIC_CLOUDFLARE_ZONE_ID"] = "music_zone"
      ENV["MOVIES_CLOUDFLARE_ZONE_ID"] = "movies_zone"
      ENV.delete("GAMES_CLOUDFLARE_ZONE_ID")
      ENV.delete("BOOKS_CLOUDFLARE_ZONE_ID")

      config = Configuration.new
      zones = config.configured_zones

      assert_equal({music: "music_zone", movies: "movies_zone"}, zones)
      assert_not_includes zones.keys, :games
      assert_not_includes zones.keys, :books
    end

    test "configured_zones returns empty hash when no zones configured" do
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test_token"
      ENV.delete("MUSIC_CLOUDFLARE_ZONE_ID")
      ENV.delete("MOVIES_CLOUDFLARE_ZONE_ID")
      ENV.delete("GAMES_CLOUDFLARE_ZONE_ID")
      ENV.delete("BOOKS_CLOUDFLARE_ZONE_ID")

      config = Configuration.new

      assert_empty config.configured_zones
    end

    test "DOMAINS constant includes all four media types" do
      assert_equal [:music, :movies, :games, :books], Configuration::DOMAINS
    end
  end
end

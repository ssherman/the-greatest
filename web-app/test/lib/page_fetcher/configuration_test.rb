# frozen_string_literal: true

require "test_helper"

module PageFetcher
  class ConfigurationTest < ActiveSupport::TestCase
    def setup
      @original_env = ENV["PAGE_FETCHER_SERVICE_URL"]
    end

    def teardown
      ENV["PAGE_FETCHER_SERVICE_URL"] = @original_env
    end

    test "defaults to the docker-published loopback address" do
      ENV.delete("PAGE_FETCHER_SERVICE_URL")

      assert_equal "http://127.0.0.1:8081", PageFetcher::Configuration.new.base_url
    end

    test "reads the base url from the environment" do
      ENV["PAGE_FETCHER_SERVICE_URL"] = "https://fetcher.example.test"

      assert_equal "https://fetcher.example.test", PageFetcher::Configuration.new.base_url
    end

    test "an explicit base_url wins over the environment variable" do
      ENV["PAGE_FETCHER_SERVICE_URL"] = "https://fetcher.example.test"

      assert_equal "http://override.test", PageFetcher::Configuration.new(base_url: "http://override.test").base_url
    end

    test "defaults the open timeout to three seconds" do
      assert_equal 3, PageFetcher::Configuration.new.open_timeout
    end

    test "sets a descriptive user agent by default" do
      assert_match(/TheGreatest/, PageFetcher::Configuration.new.user_agent)
    end

    test "defaults the logger to the Rails logger" do
      assert_equal Rails.logger, PageFetcher::Configuration.new.logger
    end

    test "rejects a blank base url" do
      ENV["PAGE_FETCHER_SERVICE_URL"] = ""

      assert_raises(PageFetcher::Exceptions::ConfigurationError) { PageFetcher::Configuration.new }
    end

    test "rejects a non-http base url" do
      assert_raises(PageFetcher::Exceptions::ConfigurationError) do
        PageFetcher::Configuration.new(base_url: "ftp://fetcher.example.test")
      end
    end

    test "rejects a malformed base url" do
      assert_raises(PageFetcher::Exceptions::ConfigurationError) do
        PageFetcher::Configuration.new(base_url: "http://bad host")
      end
    end
  end
end

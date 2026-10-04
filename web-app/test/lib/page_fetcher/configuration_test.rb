# frozen_string_literal: true

require "test_helper"

module PageFetcher
  class ConfigurationTest < ActiveSupport::TestCase
    def setup
      @original_env = ENV["PAGE_FETCHER_SERVICE_URL"]
      @original_access = ENV.to_h.slice("CLOUDFLARE_ACCESS_CLIENT_ID", "CLOUDFLARE_ACCESS_CLIENT_SECRET")
    end

    def teardown
      ENV["PAGE_FETCHER_SERVICE_URL"] = @original_env
      %w[CLOUDFLARE_ACCESS_CLIENT_ID CLOUDFLARE_ACCESS_CLIENT_SECRET].each { |k| ENV.delete(k) }
      @original_access.each { |k, v| ENV[k] = v }
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

    test "reads Cloudflare Access credentials from the environment" do
      ENV["CLOUDFLARE_ACCESS_CLIENT_ID"] = "id.access"
      ENV["CLOUDFLARE_ACCESS_CLIENT_SECRET"] = "s3cret"

      assert PageFetcher::Configuration.new.access.configured?
    end

    test "an explicit access wins over the environment" do
      ENV["CLOUDFLARE_ACCESS_CLIENT_ID"] = "id.access"
      ENV["CLOUDFLARE_ACCESS_CLIENT_SECRET"] = "s3cret"
      none = CloudflareAccess::Credentials.new(client_id: nil, client_secret: nil)

      assert_not PageFetcher::Configuration.new(access: none).access.configured?
    end

    test "rejects half of an Access pair without echoing it" do
      ENV["CLOUDFLARE_ACCESS_CLIENT_ID"] = ""
      ENV["CLOUDFLARE_ACCESS_CLIENT_SECRET"] = "s3cret"

      error = assert_raises(PageFetcher::Exceptions::ConfigurationError) { PageFetcher::Configuration.new }
      assert_not_includes error.message, "s3cret"
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Books
  module OpenLibrary
    class ConfigurationTest < ActiveSupport::TestCase
      test "defaults to the docker-published loopback address" do
        assert_equal "http://127.0.0.1:8080", Books::OpenLibrary::Configuration.new.base_url
      end

      test "reads the base url from the environment" do
        ENV["OPEN_LIBRARY_SERVICE_URL"] = "https://example.test"

        assert_equal "https://example.test", Books::OpenLibrary::Configuration.new.base_url
      ensure
        ENV.delete("OPEN_LIBRARY_SERVICE_URL")
      end

      test "an explicit base_url wins over the environment variable" do
        ENV["OPEN_LIBRARY_SERVICE_URL"] = "https://example.test"

        config = Books::OpenLibrary::Configuration.new(base_url: "http://override.test")

        assert_equal "http://override.test", config.base_url
      ensure
        ENV.delete("OPEN_LIBRARY_SERVICE_URL")
      end

      test "sets a descriptive user agent by default" do
        assert_match(/TheGreatest/, Books::OpenLibrary::Configuration.new.user_agent)
      end

      test "an explicit user_agent overrides the default" do
        config = Books::OpenLibrary::Configuration.new(user_agent: "Custom/1.0")

        assert_equal "Custom/1.0", config.user_agent
      end

      test "defaults the logger to the Rails logger" do
        assert_equal Rails.logger, Books::OpenLibrary::Configuration.new.logger
      end

      test "an explicit logger overrides the default" do
        logger = Logger.new(nil)

        config = Books::OpenLibrary::Configuration.new(logger: logger)

        assert_equal logger, config.logger
      end

      test "rejects a blank base url" do
        ENV["OPEN_LIBRARY_SERVICE_URL"] = ""

        assert_raises(Books::OpenLibrary::Exceptions::ConfigurationError) { Books::OpenLibrary::Configuration.new }
      ensure
        ENV.delete("OPEN_LIBRARY_SERVICE_URL")
      end

      test "rejects a non-http base url" do
        ENV["OPEN_LIBRARY_SERVICE_URL"] = "ftp://example.test"

        assert_raises(Books::OpenLibrary::Exceptions::ConfigurationError) { Books::OpenLibrary::Configuration.new }
      ensure
        ENV.delete("OPEN_LIBRARY_SERVICE_URL")
      end

      test "has the documented timeouts" do
        config = Books::OpenLibrary::Configuration.new

        assert_equal 10, config.timeout
        assert_equal 3, config.open_timeout
        assert_equal 60, config.resolve_timeout
      end

      test "explicit timeout overrides win over the defaults" do
        config = Books::OpenLibrary::Configuration.new(timeout: 1, open_timeout: 2, resolve_timeout: 3)

        assert_equal 1, config.timeout
        assert_equal 2, config.open_timeout
        assert_equal 3, config.resolve_timeout
      end
    end
  end
end

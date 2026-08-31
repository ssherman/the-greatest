# frozen_string_literal: true

require "test_helper"

class Viaf::ConfigurationTest < ActiveSupport::TestCase
  test "defaults to the public VIAF host" do
    assert_equal "https://viaf.org", Viaf::Configuration.new.base_url
  end

  test "reads the base url from the environment" do
    ENV["VIAF_URL"] = "https://example.test"

    assert_equal "https://example.test", Viaf::Configuration.new.base_url
  ensure
    ENV.delete("VIAF_URL")
  end

  test "sets a descriptive user agent" do
    assert_match(/TheGreatest/, Viaf::Configuration.new.user_agent)
  end

  test "defaults the logger to the Rails logger" do
    assert_equal Rails.logger, Viaf::Configuration.new.logger
  end

  test "rejects a blank base url" do
    ENV["VIAF_URL"] = ""

    assert_raises(ArgumentError) { Viaf::Configuration.new }
  ensure
    ENV.delete("VIAF_URL")
  end

  test "rejects a non-http base url" do
    ENV["VIAF_URL"] = "ftp://viaf.org"

    assert_raises(ArgumentError) { Viaf::Configuration.new }
  ensure
    ENV.delete("VIAF_URL")
  end

  test "has sane timeouts" do
    config = Viaf::Configuration.new

    assert_equal 30, config.timeout
    assert_equal 10, config.open_timeout
  end
end

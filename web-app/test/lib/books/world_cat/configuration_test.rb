require "test_helper"

module Books
  module WorldCat
    class ConfigurationTest < ActiveSupport::TestCase
      test "reads WORLDCAT_SERVICE_URL and applies the lookup timeouts" do
        config = Configuration.new(base_url: "http://wc.test:8082")
        assert_equal ["http://wc.test:8082", 30, 3, 30], [config.base_url, config.timeout, config.open_timeout, config.batch_timeout]
      end

      test "defaults to the local port when the variable is unset" do
        saved = ENV.delete("WORLDCAT_SERVICE_URL")
        assert_equal "http://127.0.0.1:8082", Configuration.new.base_url
      ensure
        ENV["WORLDCAT_SERVICE_URL"] = saved if saved
      end

      test "rejects a blank or non-http url naming the variable" do
        error = assert_raises(Exceptions::ConfigurationError) { Configuration.new(base_url: "ftp://x") }
        assert_match(/WORLDCAT_SERVICE_URL/, error.message)
        assert_raises(Exceptions::ConfigurationError) { Configuration.new(base_url: "") }
      end

      test "a partial Access credential pair is a configuration error" do
        access = CloudflareAccess::Credentials.new(client_id: "id", client_secret: nil)
        assert_raises(Exceptions::ConfigurationError) { Configuration.new(base_url: "http://wc.test", access: access) }
      end
    end
  end
end

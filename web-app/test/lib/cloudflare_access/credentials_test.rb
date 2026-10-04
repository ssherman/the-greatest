# frozen_string_literal: true

require "test_helper"

module CloudflareAccess
  class CredentialsTest < ActiveSupport::TestCase
    def setup
      @original = ENV.to_h.slice("CLOUDFLARE_ACCESS_CLIENT_ID", "CLOUDFLARE_ACCESS_CLIENT_SECRET")
    end

    def teardown
      %w[CLOUDFLARE_ACCESS_CLIENT_ID CLOUDFLARE_ACCESS_CLIENT_SECRET].each { |k| ENV.delete(k) }
      @original.each { |k, v| ENV[k] = v }
    end

    test "both halves produce the two Access headers" do
      credentials = Credentials.new(client_id: "id.access", client_secret: "s3cret")

      assert credentials.configured?
      assert_not credentials.partial?
      assert_equal({"CF-Access-Client-Id" => "id.access", "CF-Access-Client-Secret" => "s3cret"}, credentials.headers)
    end

    test "neither half is unconfigured and sends no headers" do
      credentials = Credentials.new(client_id: nil, client_secret: "")

      assert_not credentials.configured?
      assert_not credentials.partial?
      assert_equal({}, credentials.headers)
    end

    test "one half alone is partial and sends no headers" do
      credentials = Credentials.new(client_id: "id.access", client_secret: " ")

      assert credentials.partial?
      assert_not credentials.configured?
      assert_equal({}, credentials.headers)
    end

    test "from_env reads both variables" do
      ENV["CLOUDFLARE_ACCESS_CLIENT_ID"] = "id.access"
      ENV["CLOUDFLARE_ACCESS_CLIENT_SECRET"] = "s3cret"

      assert_equal "s3cret", Credentials.from_env.headers["CF-Access-Client-Secret"]
    end

    test "inspect and to_s never show the secret" do
      credentials = Credentials.new(client_id: "id.access", client_secret: "s3cret")

      assert_not_includes credentials.inspect, "s3cret"
      assert_not_includes credentials.to_s, "s3cret"
    end
  end
end

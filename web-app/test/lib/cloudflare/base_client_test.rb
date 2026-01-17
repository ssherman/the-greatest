# frozen_string_literal: true

require "test_helper"

module Cloudflare
  class BaseClientTest < ActiveSupport::TestCase
    setup do
      @original_env = ENV.to_hash
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test_token"
      @config = Configuration.new
      @client = BaseClient.new(@config)
    end

    teardown do
      ENV.clear
      ENV.update(@original_env)
    end

    test "post sends request with Bearer token authorization" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/abc123/purge_cache")
        .with(
          headers: {"Authorization" => "Bearer test_token", "Content-Type" => "application/json"},
          body: {purge_everything: true}.to_json
        )
        .to_return(
          status: 200,
          body: {success: true, result: {id: "purge_123"}}.to_json,
          headers: {"Content-Type" => "application/json"}
        )

      result = @client.post("zones/abc123/purge_cache", body: {purge_everything: true})

      assert result[:success]
      assert_equal "purge_123", result[:result]["id"]
    end

    test "post returns metadata with response time" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/test_endpoint")
        .to_return(
          status: 200,
          body: {success: true, result: {}}.to_json,
          headers: {"Content-Type" => "application/json"}
        )

      result = @client.post("test_endpoint", body: {})

      assert_includes result.keys, :metadata
      assert_includes result[:metadata].keys, :response_time
      assert_includes result[:metadata].keys, :status_code
      assert_equal 200, result[:metadata][:status_code]
    end

    test "post raises AuthenticationError on 401 response" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/test_endpoint")
        .to_return(status: 401, body: "Unauthorized")

      error = assert_raises(Cloudflare::Exceptions::AuthenticationError) do
        @client.post("test_endpoint", body: {})
      end

      assert_equal 401, error.status_code
    end

    test "post raises AuthenticationError on 403 response" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/test_endpoint")
        .to_return(status: 403, body: "Forbidden")

      error = assert_raises(Cloudflare::Exceptions::AuthenticationError) do
        @client.post("test_endpoint", body: {})
      end

      assert_equal 403, error.status_code
    end

    test "post raises RateLimitError on 429 response" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/test_endpoint")
        .to_return(status: 429, body: "Rate limited")

      error = assert_raises(Cloudflare::Exceptions::RateLimitError) do
        @client.post("test_endpoint", body: {})
      end

      assert_equal 429, error.status_code
    end

    test "post raises ServerError on 500 response" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/test_endpoint")
        .to_return(status: 500, body: "Internal Server Error")

      error = assert_raises(Cloudflare::Exceptions::ServerError) do
        @client.post("test_endpoint", body: {})
      end

      assert_equal 500, error.status_code
    end

    test "post raises HttpError when API returns success false" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/test_endpoint")
        .to_return(
          status: 200,
          body: {success: false, errors: [{message: "Invalid zone"}]}.to_json,
          headers: {"Content-Type" => "application/json"}
        )

      error = assert_raises(Cloudflare::Exceptions::HttpError) do
        @client.post("test_endpoint", body: {})
      end

      assert_match(/Invalid zone/, error.message)
    end

    test "post raises NetworkError on timeout" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/test_endpoint")
        .to_timeout

      assert_raises(Cloudflare::Exceptions::NetworkError) do
        @client.post("test_endpoint", body: {})
      end
    end

    test "post raises NetworkError on connection failure" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/test_endpoint")
        .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

      error = assert_raises(Cloudflare::Exceptions::NetworkError) do
        @client.post("test_endpoint", body: {})
      end

      assert_match(/Connection failed/, error.message)
    end
  end
end

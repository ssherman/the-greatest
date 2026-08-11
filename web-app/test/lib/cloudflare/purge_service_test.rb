# frozen_string_literal: true

require "test_helper"

module Cloudflare
  class PurgeServiceTest < ActiveSupport::TestCase
    setup do
      @original_env = ENV.to_hash
      ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test_token"
      ENV["MUSIC_CLOUDFLARE_ZONE_ID"] = "music_zone_123"
      ENV["MOVIES_CLOUDFLARE_ZONE_ID"] = "movies_zone_456"
      ENV.delete("GAMES_CLOUDFLARE_ZONE_ID")
      ENV.delete("BOOKS_CLOUDFLARE_ZONE_ID")
    end

    teardown do
      ENV.clear
      ENV.update(@original_env)
    end

    test "purge_zones purges single zone successfully" do
      stub_cloudflare_purge("music_zone_123", success: true)

      service = PurgeService.new
      result = service.purge_zones([:music])

      assert result[:success]
      assert result[:results][:music][:success]
      assert_equal "purge_123", result[:results][:music][:purge_id]
    end

    test "purge_zones purges multiple zones successfully" do
      stub_cloudflare_purge("music_zone_123", success: true)
      stub_cloudflare_purge("movies_zone_456", success: true)

      service = PurgeService.new
      result = service.purge_zones([:music, :movies])

      assert result[:success]
      assert result[:results][:music][:success]
      assert result[:results][:movies][:success]
    end

    test "purge_zones handles partial failure" do
      stub_cloudflare_purge("music_zone_123", success: true)
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/movies_zone_456/purge_cache")
        .to_return(status: 500, body: "Server Error")

      service = PurgeService.new
      result = service.purge_zones([:music, :movies])

      assert_not result[:success]
      assert result[:results][:music][:success]
      assert_not result[:results][:movies][:success]
      assert result[:results][:movies][:error].present?
    end

    test "purge_zones returns error for unconfigured zone" do
      service = PurgeService.new
      result = service.purge_zones([:games])

      assert_not result[:success]
      assert_not result[:results][:games][:success]
      assert_match(/not configured/, result[:results][:games][:error])
    end

    test "purge_all_zones purges all configured zones" do
      stub_cloudflare_purge("music_zone_123", success: true)
      stub_cloudflare_purge("movies_zone_456", success: true)

      service = PurgeService.new
      result = service.purge_all_zones

      assert result[:success]
      assert_equal 2, result[:results].keys.size
      assert result[:results][:music][:success]
      assert result[:results][:movies][:success]
    end

    test "purge_all_zones returns error when no zones configured" do
      ENV.delete("MUSIC_CLOUDFLARE_ZONE_ID")
      ENV.delete("MOVIES_CLOUDFLARE_ZONE_ID")

      service = PurgeService.new
      result = service.purge_all_zones

      assert_not result[:success]
      assert_match(/No Cloudflare zones configured/, result[:error])
    end

    test "purge_zones handles authentication error" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/music_zone_123/purge_cache")
        .to_return(status: 401, body: "Unauthorized")

      service = PurgeService.new
      result = service.purge_zones([:music])

      assert_not result[:success]
      assert_not result[:results][:music][:success]
      assert_match(/Authentication failed/, result[:results][:music][:error])
    end

    test "purge_zones handles rate limit error" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/music_zone_123/purge_cache")
        .to_return(status: 429, body: "Rate limited")

      service = PurgeService.new
      result = service.purge_zones([:music])

      assert_not result[:success]
      assert_match(/Rate limit/, result[:results][:music][:error])
    end

    test "purge_zones handles timeout" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/music_zone_123/purge_cache")
        .to_timeout

      service = PurgeService.new
      result = service.purge_zones([:music])

      assert_not result[:success]
      assert result[:results][:music][:error].present?
    end

    private

    def stub_cloudflare_purge(zone_id, success:)
      stub_request(:post, "https://api.cloudflare.com/client/v4/zones/#{zone_id}/purge_cache")
        .with(
          headers: {"Authorization" => "Bearer test_token"},
          body: {purge_everything: true}.to_json
        )
        .to_return(
          status: 200,
          body: {success: success, result: {id: "purge_123"}}.to_json,
          headers: {"Content-Type" => "application/json"}
        )
    end
  end

  class PurgeServiceUrlsTest < ActiveSupport::TestCase
    setup do
      @config = mock("config")
      @client = mock("client")
    end

    test "posts the urls as a files body to the domain's zone" do
      @config.expects(:zone_id).with(:books).returns("zone-abc")
      @client.expects(:post)
        .with("zones/zone-abc/purge_cache", body: {files: ["https://example.test/book/x"]})
        .returns({result: {"id" => "purge-1"}, metadata: {response_time: 0.1}})

      service = PurgeService.new(client: @client, config: @config)
      result = service.purge_urls(:books, ["https://example.test/book/x"])

      assert result[:success]
    end

    # Regression: result[:result]["id"] raised NoMethodError on a null `result`, which
    # is not an Exceptions::Error and so escaped the rescue below despite the purge
    # itself having succeeded -- failing the Sidekiq job through all its retries.
    test "succeeds without raising when the api response has a null result payload" do
      @config.expects(:zone_id).with(:books).returns("zone-abc")
      @client.expects(:post)
        .with("zones/zone-abc/purge_cache", body: {files: ["https://example.test/book/x"]})
        .returns({result: nil, metadata: {response_time: 0.1}})

      result = PurgeService.new(client: @client, config: @config).purge_urls(:books, ["https://example.test/book/x"])

      assert result[:success]
      assert_nil result[:purge_id]
    end

    test "reports failure without raising when the zone is not configured" do
      @config.expects(:zone_id).with(:books).returns(nil)
      @client.expects(:post).never

      result = PurgeService.new(client: @client, config: @config).purge_urls(:books, ["https://example.test/x"])

      refute result[:success]
      assert_match(/not configured/i, result[:error])
    end

    test "reports failure without raising when the api call errors" do
      @config.expects(:zone_id).with(:books).returns("zone-abc")
      @client.expects(:post).raises(Cloudflare::Exceptions::NetworkError.new("boom"))

      result = PurgeService.new(client: @client, config: @config).purge_urls(:books, ["https://example.test/x"])

      refute result[:success]
      assert_match(/boom/, result[:error])
    end

    test "does nothing for an empty url list" do
      @client.expects(:post).never

      result = PurgeService.new(client: @client, config: @config).purge_urls(:books, [])

      refute result[:success]
    end
  end
end

# frozen_string_literal: true

require "test_helper"

class Admin::CloudflareControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @regular_user = users(:regular_user)

    @original_env = ENV.to_hash
    ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = "test_token"
    ENV["MUSIC_CLOUDFLARE_ZONE_ID"] = "music_zone_123"

    host! Rails.application.config.domains[:music]
    sign_in_as(@admin, stub_auth: true)
  end

  teardown do
    ENV.clear
    ENV.update(@original_env)
  end

  test "purge_cache succeeds for admin with valid type" do
    stub_cloudflare_purge("music_zone_123", success: true)

    post purge_cache_admin_cloudflare_url(type: :music)

    assert_redirected_to admin_root_path
    assert_match(/successfully/, flash[:success])
  end

  test "purge_cache returns error for invalid type" do
    post purge_cache_admin_cloudflare_url(type: :invalid)

    assert_redirected_to admin_root_path
    assert_match(/Invalid domain type/, flash[:error])
  end

  test "purge_cache returns error when type is missing" do
    post purge_cache_admin_cloudflare_url

    assert_redirected_to admin_root_path
    assert_match(/Invalid domain type/, flash[:error])
  end

  test "purge_cache shows error on API failure" do
    stub_request(:post, "https://api.cloudflare.com/client/v4/zones/music_zone_123/purge_cache")
      .to_return(status: 500, body: "Server Error")

    post purge_cache_admin_cloudflare_url(type: :music)

    assert_redirected_to admin_root_path
    assert_match(/Failed to purge/, flash[:error])
  end

  test "purge_cache shows configuration error when token missing" do
    ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")

    post purge_cache_admin_cloudflare_url(type: :music)

    assert_redirected_to admin_root_path
    assert_match(/configuration error/, flash[:error])
  end

  test "purge_cache denies access to regular users" do
    sign_in_as(@regular_user, stub_auth: true)

    post purge_cache_admin_cloudflare_url(type: :music)

    assert_redirected_to music_root_url
    assert_match(/Access denied/, flash[:alert])
  end

  test "purge_cache denies access to editors" do
    sign_in_as(@editor, stub_auth: true)

    post purge_cache_admin_cloudflare_url(type: :music)

    assert_redirected_to music_root_url
    assert_match(/Admin role required/, flash[:alert])
  end

  test "purge_cache allows admin access" do
    stub_cloudflare_purge("music_zone_123", success: true)

    post purge_cache_admin_cloudflare_url(type: :music)

    assert_redirected_to admin_root_path
    assert flash[:success].present?
  end

  private

  def stub_cloudflare_purge(zone_id, success:)
    stub_request(:post, "https://api.cloudflare.com/client/v4/zones/#{zone_id}/purge_cache")
      .to_return(
        status: 200,
        body: {success: success, result: {id: "purge_123"}}.to_json,
        headers: {"Content-Type" => "application/json"}
      )
  end
end

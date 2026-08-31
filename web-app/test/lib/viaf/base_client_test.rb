# frozen_string_literal: true

require "test_helper"

class Viaf::BaseClientTest < ActiveSupport::TestCase
  def setup
    @config = Viaf::Configuration.new
    @config.base_url = "https://viaf.test"
    @limiter = mock("rate_limiter")
    @limiter.stubs(:wait!)
    Viaf::RateLimiter.stubs(:new).returns(@limiter)
    @client = Viaf::BaseClient.new(@config)
  end

  test "sends an Accept: application/json header" do
    stub = stub_request(:get, "https://viaf.test/viaf/96987389")
      .with(headers: {"Accept" => "application/json"})
      .to_return(status: 200, body: '{"ok":true}', headers: {"Content-Type" => "application/json"})

    @client.get("viaf/96987389")

    assert_requested stub
  end

  test "sends the configured User-Agent" do
    stub = stub_request(:get, "https://viaf.test/viaf/1")
      .with(headers: {"User-Agent" => @config.user_agent})
      .to_return(status: 200, body: "{}", headers: {"Content-Type" => "application/json"})

    @client.get("viaf/1")

    assert_requested stub
  end

  test "acquires a rate limit slot before every request" do
    stub_request(:get, "https://viaf.test/viaf/1")
      .to_return(status: 200, body: "{}", headers: {"Content-Type" => "application/json"})

    @limiter.expects(:wait!).once

    @client.get("viaf/1")
  end

  test "returns parsed data on success" do
    stub_request(:get, "https://viaf.test/viaf/1")
      .to_return(status: 200, body: '{"ns1:viafID":1}', headers: {"Content-Type" => "application/json"})

    result = @client.get("viaf/1")

    assert result[:success]
    assert_equal({"ns1:viafID" => 1}, result[:data])
    assert_empty result[:errors]
  end

  test "includes path, status_code, and response_time in success metadata" do
    stub_request(:get, "https://viaf.test/viaf/1")
      .to_return(status: 200, body: '{"ns1:viafID":1}', headers: {"Content-Type" => "application/json"})

    result = @client.get("viaf/1")

    assert_equal "viaf/1", result[:metadata][:path]
    assert_equal 200, result[:metadata][:status_code]
    assert_kind_of Numeric, result[:metadata][:response_time]
  end

  test "captures rate limit headers into metadata" do
    stub_request(:get, "https://viaf.test/viaf/1").to_return(
      status: 200,
      body: "{}",
      headers: {
        "Content-Type" => "application/json",
        "ratelimit-limit" => "1003",
        "ratelimit-remaining" => "998",
        "x-ratelimit-remaining-day" => "998"
      }
    )

    result = @client.get("viaf/1")

    assert_equal 998, result[:metadata][:rate_limit][:remaining]
    assert_equal 1003, result[:metadata][:rate_limit][:limit]
    assert_equal 998, @client.last_rate_limit[:remaining_day]
  end

  test "raises BlockedError on a Cloudflare 403, not ParseError" do
    body = file_fixture("viaf/cloudflare_blocked.html").read
    stub_request(:get, "https://viaf.test/viaf/1")
      .to_return(status: 403, body: body, headers: {"Content-Type" => "text/html"})

    error = assert_raises(Viaf::Exceptions::BlockedError) { @client.get("viaf/1") }

    assert_equal 403, error.status_code
    assert_match(/blocked/i, error.message)
  end

  test "raises BlockedError on a 200 Cloudflare interstitial, not ParseError" do
    body = file_fixture("viaf/cloudflare_blocked.html").read
    stub_request(:get, "https://viaf.test/viaf/1")
      .to_return(status: 200, body: body, headers: {"Content-Type" => "text/html"})

    error = assert_raises(Viaf::Exceptions::BlockedError) { @client.get("viaf/1") }

    assert_equal 200, error.status_code
    assert_match(/blocked/i, error.message)
  end

  test "raises NotFoundError on 404" do
    stub_request(:get, "https://viaf.test/viaf/nope")
      .to_return(status: 404, body: '{"message":"not found"}')

    assert_raises(Viaf::Exceptions::NotFoundError) { @client.get("viaf/nope") }
  end

  test "captures last_rate_limit even when the response is an error" do
    stub_request(:get, "https://viaf.test/viaf/nope").to_return(
      status: 404,
      body: '{"message":"not found"}',
      headers: {
        "ratelimit-limit" => "1003",
        "ratelimit-remaining" => "500"
      }
    )

    assert_raises(Viaf::Exceptions::NotFoundError) { @client.get("viaf/nope") }

    assert_equal 500, @client.last_rate_limit[:remaining]
  end

  test "raises ServerError on 500" do
    stub_request(:get, "https://viaf.test/viaf/1").to_return(status: 500, body: "boom")

    assert_raises(Viaf::Exceptions::ServerError) { @client.get("viaf/1") }
  end

  test "raises ParseError when a 200 body is not JSON" do
    stub_request(:get, "https://viaf.test/viaf/1")
      .to_return(status: 200, body: "<html>nope</html>", headers: {"Content-Type" => "text/html"})

    assert_raises(Viaf::Exceptions::ParseError) { @client.get("viaf/1") }
  end

  # WebMock's to_timeout raises Net::OpenTimeout, which Faraday's net_http
  # adapter maps to ConnectionFailed rather than TimeoutError. Assert on the
  # NetworkError parent so this holds either way (TimeoutError < NetworkError).
  test "raises NetworkError when the connection times out" do
    stub_request(:get, "https://viaf.test/viaf/1").to_timeout

    assert_raises(Viaf::Exceptions::NetworkError) { @client.get("viaf/1") }
  end

  test "raises TimeoutError when Faraday reports a read timeout" do
    stub_request(:get, "https://viaf.test/viaf/1").to_raise(Faraday::TimeoutError)

    assert_raises(Viaf::Exceptions::TimeoutError) { @client.get("viaf/1") }
  end

  test "follows redirects for merged clusters" do
    stub_request(:get, "https://viaf.test/viaf/111")
      .to_return(status: 301, headers: {"Location" => "https://viaf.test/viaf/222"})
    stub_request(:get, "https://viaf.test/viaf/222")
      .to_return(status: 200, body: '{"ns1:viafID":222}', headers: {"Content-Type" => "application/json"})

    result = @client.get("viaf/111")

    assert_equal({"ns1:viafID" => 222}, result[:data])
  end
end

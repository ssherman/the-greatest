# frozen_string_literal: true

require "test_helper"

module Wikimedia
  class HttpTest < ActiveSupport::TestCase
    API = "https://www.wikidata.org/w/api.php"
    SPARQL = "https://query.wikidata.org/sparql"
    AGENT = "TheGreatest/1.0 (https://example.org/contact)"

    def setup
      @settings = ActiveSupport::OrderedOptions.new.merge(
        requests_per_window: 1, window_seconds: 1.0, max_inline_wait: 5.0, maxlag: 5,
        contact: "https://example.org/contact"
      )
      @limiter = mock("limiter")
      @limiter.stubs(:acquire!)
      @slept = []
      @http = Http.new(settings: @settings, limiter: @limiter, sleeper: ->(seconds) { @slept << seconds })
    end

    def json(body, status: 200, headers: {})
      {status: status, body: body.to_json, headers: {"Content-Type" => "application/json"}.merge(headers)}
    end

    def busy(retry_after)
      ::DistributedRateLimiter::RateLimitExceeded.new("busy", key: "wikimedia:api", retry_after: retry_after)
    end

    test "builds the shared limiter on the wikimedia:api key in immediate mode" do
      ::DistributedRateLimiter.expects(:new)
        .with(key: "wikimedia:api", limit: 1, window: 1.0, mode: :immediate)
        .returns(@limiter)

      Http.new(settings: @settings)
    end

    test "sends the policy User-Agent, JSON format, formatversion 2 and maxlag on Action API calls" do
      stub = stub_request(:get, API)
        .with(
          query: {action: "wbgetentities", ids: "Q1", format: "json", formatversion: "2", maxlag: "5"},
          headers: {"User-Agent" => AGENT}
        )
        .to_return(json({entities: {}}))

      @http.action_api(API, action: "wbgetentities", ids: "Q1")

      assert_requested stub
    end

    test "returns the parsed data and the raw body" do
      stub_request(:get, API).with(query: hash_including(action: "wbsearchentities")).to_return(json({search: []}))

      response = @http.action_api(API, action: "wbsearchentities")

      assert_equal({"search" => []}, response.data)
      assert_equal({search: []}.to_json, response.body)
    end

    test "a 429 raises RateLimited carrying Retry-After" do
      stub_request(:get, API).with(query: hash_including({})).to_return(status: 429, body: "", headers: {"Retry-After" => "120"})

      error = assert_raises(Exceptions::RateLimited) { @http.action_api(API, action: "query") }

      assert_equal 120, error.retry_after
    end

    test "a 429 without Retry-After waits the default" do
      stub_request(:get, API).with(query: hash_including({})).to_return(status: 429, body: "")

      error = assert_raises(Exceptions::RateLimited) { @http.action_api(API, action: "query") }

      assert_equal Http::DEFAULT_RETRY_AFTER, error.retry_after
    end

    test "a maxlag error raises RateLimited carrying Retry-After" do
      body = {error: {code: "maxlag", info: "Waiting for db1: 6 seconds lagged", lag: 6}}
      stub_request(:get, API).with(query: hash_including({})).to_return(json(body, headers: {"Retry-After" => "5"}))

      error = assert_raises(Exceptions::RateLimited) { @http.action_api(API, action: "query") }

      assert_equal 5, error.retry_after
    end

    test "RateLimited is not a Wikimedia error, so a rescue of Error never swallows it" do
      assert_not Exceptions::RateLimited <= Exceptions::Error
    end

    test "another Action API error raises ApiError with its code" do
      body = {error: {code: "no-such-entity", info: "Could not find an entity with the ID Q0."}}
      stub_request(:get, API).with(query: hash_including({})).to_return(json(body))

      error = assert_raises(Exceptions::ApiError) { @http.action_api(API, action: "wbgetentities") }

      assert_equal "no-such-entity", error.code
    end

    test "a 403 raises HttpError naming the User-Agent policy" do
      stub_request(:get, API).with(query: hash_including({})).to_return(status: 403, body: "Forbidden")

      error = assert_raises(Exceptions::HttpError) { @http.action_api(API, action: "query") }

      assert_equal 403, error.status_code
      assert_match(/User-Agent/, error.message)
    end

    test "a 500 raises HttpError" do
      stub_request(:get, API).with(query: hash_including({})).to_return(status: 500, body: "oops")

      error = assert_raises(Exceptions::HttpError) { @http.action_api(API, action: "query") }

      assert_equal 500, error.status_code
    end

    test "invalid JSON raises ParseError" do
      stub_request(:get, API).with(query: hash_including({})).to_return(status: 200, body: "<html>")

      assert_raises(Exceptions::ParseError) { @http.action_api(API, action: "query") }
    end

    # WebMock's to_timeout raises Net::OpenTimeout, which Faraday's net_http
    # adapter maps to Faraday::ConnectionFailed (not a timeout-specific
    # error), so the code raises NetworkError, not TimeoutError. See
    # test/lib/viaf/base_client_test.rb lines 142-153 for the same situation.
    # A real Faraday::TimeoutError (a slow-but-connected server) is the case
    # that maps to TimeoutError.
    test "a connection-level timeout raises NetworkError" do
      stub_request(:get, API).with(query: hash_including({})).to_timeout

      assert_raises(Exceptions::NetworkError) { @http.action_api(API, action: "query") }
    end

    test "a Faraday read timeout raises TimeoutError" do
      stub_request(:get, API).with(query: hash_including({})).to_raise(Faraday::TimeoutError)

      assert_raises(Exceptions::TimeoutError) { @http.action_api(API, action: "query") }
    end

    test "SPARQL posts the query with the results Accept header and the User-Agent" do
      stub = stub_request(:post, SPARQL)
        .with(body: {query: "ASK {}"}, headers: {"Accept" => "application/sparql-results+json", "User-Agent" => AGENT})
        .to_return(json({boolean: true}))

      response = @http.sparql(SPARQL, "ASK {}")

      assert_requested stub
      assert_equal true, response.data["boolean"]
    end

    test "waits inline for a busy slot, then sends" do
      @limiter.stubs(:acquire!).raises(busy(0.4)).then.returns({allowed: true})
      stub = stub_request(:get, API).with(query: hash_including({})).to_return(json({}))

      @http.action_api(API, action: "query")

      assert_equal [0.4], @slept
      assert_requested stub
    end

    test "raises RateLimited, without sending, when the slot stays busy past max_inline_wait" do
      @limiter.stubs(:acquire!).raises(busy(3.0))
      stub = stub_request(:get, API).with(query: hash_including({})).to_return(json({}))

      error = assert_raises(Exceptions::RateLimited) { @http.action_api(API, action: "query") }

      assert_equal [3.0], @slept
      assert_equal 3, error.retry_after
      assert_not_requested stub
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Wikidata
  class ServiceTest < ActiveSupport::TestCase
    BASE = "http://wd.test:8083"

    def setup
      @breaker = Books::OpenLibrary::CircuitBreaker.new(key: "test:wikidata:service", failure_threshold: 5, cooldown: 60,
        redis: Books::OpenLibrary::FakeRedis.new)
      @service = Service.new(Configuration.new(base_url: BASE, logger: nil), breaker: @breaker)
    end

    test "post sends a JSON body and returns the parsed answer" do
      stub = stub_request(:post, "#{BASE}/items").with(body: {ids: ["Q1"]}.to_json, headers: {"Content-Type" => "application/json"})
        .to_return(status: 200, body: {items: {}}.to_json)

      assert_equal({"items" => {}}, @service.post("/items", {ids: ["Q1"]}))
      assert_requested stub
    end

    test "get sends query parameters" do
      stub_request(:get, "#{BASE}/names").with(query: {q: "x", limit: "10"}).to_return(status: 200, body: {hits: []}.to_json)

      assert_equal({"hits" => []}, @service.get("/names", {q: "x", limit: 10}))
    end

    test "sends User-Agent, Accept and the Access headers" do
      access = CloudflareAccess::Credentials.new(client_id: "cid", client_secret: "sec")
      service = Service.new(Configuration.new(base_url: BASE, logger: nil, access: access), breaker: @breaker)
      stub_request(:get, "#{BASE}/version").to_return(status: 200, body: "{}")

      service.get("/version")

      assert_requested :get, "#{BASE}/version", headers: {"Accept" => "application/json", "CF-Access-Client-Id" => "cid", "CF-Access-Client-Secret" => "sec"}
    end

    test "5xx raises Unavailable, 4xx raises ServiceError" do
      stub_request(:get, "#{BASE}/a").to_return(status: 503, body: "{}")
      stub_request(:get, "#{BASE}/b").to_return(status: 404, body: "{}")

      assert_raises(Exceptions::Unavailable) { @service.get("/a") }
      assert_raises(Exceptions::ServiceError) { @service.get("/b") }
    end

    test "five 4xx answers leave the circuit closed; five 5xx answers open it, and an open circuit is Unavailable" do
      stub_request(:get, "#{BASE}/b").to_return(status: 422, body: "{}")
      5.times { assert_raises(Exceptions::ServiceError) { @service.get("/b") } }
      assert_not @breaker.open?

      stub_request(:get, "#{BASE}/a").to_return(status: 500, body: "{}")
      5.times { assert_raises(Exceptions::Unavailable) { @service.get("/a") } }
      assert @breaker.open?

      error = assert_raises(Exceptions::Unavailable) { @service.get("/a") }
      assert_requested :get, "#{BASE}/a", times: 5
      assert_equal 300, error.retry_after
    end

    test "configuration rejects a half-set Access token and a bad URL" do
      partial = CloudflareAccess::Credentials.new(client_id: "cid", client_secret: nil)

      assert_raises(Exceptions::ConfigurationError) { Configuration.new(logger: nil, access: partial) }
      assert_raises(Exceptions::ConfigurationError) { Configuration.new(base_url: "ftp://x", logger: nil) }
      assert_raises(Exceptions::ConfigurationError) { Configuration.new(base_url: "", logger: nil) }
      assert_equal "http://127.0.0.1:8083", Configuration.new(logger: nil).base_url
    end
  end
end

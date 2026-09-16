# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Books
  module OpenLibrary
    class BaseClientTest < ActiveSupport::TestCase
      BASE_URL = "http://open-library.test:8080"

      # Minimal Faraday::Request/Response doubles for the per-call timeout test
      # below. WebMock can't observe Faraday's per-request `options.timeout` --
      # it's a Net::HTTP socket setting, not part of the HTTP request itself --
      # so that test stubs the connection's #get instead of going over the wire.
      class FakeFaradayRequest
        attr_accessor :params, :headers, :options

        def initialize
          @headers = {}
          @options = OpenStruct.new
        end
      end

      FakeFaradayResponse = Struct.new(:status, :body)

      def setup
        @config = Books::OpenLibrary::Configuration.new(base_url: BASE_URL)
        @redis = FakeRedis.new
        @breaker = Books::OpenLibrary::CircuitBreaker.new(
          key: "test:open_library:base_client",
          failure_threshold: 5,
          cooldown: 60,
          redis: @redis
        )
        @client = Books::OpenLibrary::BaseClient.new(@config, breaker: @breaker)
      end

      test "initializes with a default configuration and breaker when none given" do
        client = Books::OpenLibrary::BaseClient.new

        assert_instance_of Books::OpenLibrary::Configuration, client.config
        assert_instance_of Books::OpenLibrary::CircuitBreaker, client.breaker
      end

      test "a 200 response returns the parsed body and metadata" do
        stub_request(:get, "#{BASE_URL}/works/OL1W")
          .to_return(status: 200, body: '{"title":"Test Work"}')

        result = @client.get("/works/OL1W")

        assert result[:success]
        assert_equal({"title" => "Test Work"}, result[:data])
        assert_empty result[:errors]
        assert_equal "/works/OL1W", result[:metadata][:path]
        assert_kind_of Float, result[:metadata][:response_time]
        assert_equal 200, result[:metadata][:status_code]
      end

      test "sends the configured User-Agent and a JSON Accept header on every request" do
        stub_request(:get, "#{BASE_URL}/works/OL1W").to_return(status: 200, body: "{}")

        @client.get("/works/OL1W")

        assert_requested :get, "#{BASE_URL}/works/OL1W",
          headers: {"User-Agent" => @config.user_agent, "Accept" => "application/json"}
      end

      test "a 404 raises NotFoundError" do
        stub_request(:get, "#{BASE_URL}/works/missing").to_return(status: 404, body: "not found")

        error = assert_raises(Books::OpenLibrary::Exceptions::NotFoundError) { @client.get("/works/missing") }

        assert_equal 404, error.status_code
        assert_equal "not found", error.response_body
      end

      test "a 422 raises ClientError" do
        stub_request(:get, "#{BASE_URL}/resolve").to_return(status: 422, body: '{"detail":"bad field"}')

        error = assert_raises(Books::OpenLibrary::Exceptions::ClientError) { @client.get("/resolve") }

        assert_equal 422, error.status_code
        assert_equal '{"detail":"bad field"}', error.response_body
        assert_not_instance_of Books::OpenLibrary::Exceptions::NotFoundError, error
      end

      test "a 500 raises ServerError" do
        stub_request(:get, "#{BASE_URL}/works/OL1W").to_return(status: 500, body: "boom")

        error = assert_raises(Books::OpenLibrary::Exceptions::ServerError) { @client.get("/works/OL1W") }

        assert_equal 500, error.status_code
        assert_equal "boom", error.response_body
      end

      test "a Faraday timeout raises Exceptions::TimeoutError" do
        # WebMock's own .to_timeout raises Net::OpenTimeout, which
        # faraday-net_http maps to Faraday::ConnectionFailed (it's in that
        # adapter's open-timeout exception list, not its read-timeout one) --
        # so it exercises the connection-failure branch below, not this one.
        # Raise Faraday::TimeoutError directly to test this mapping.
        stub_request(:get, "#{BASE_URL}/works/OL1W").to_raise(Faraday::TimeoutError)

        assert_raises(Books::OpenLibrary::Exceptions::TimeoutError) { @client.get("/works/OL1W") }
      end

      test "a connection failure raises NetworkError" do
        stub_request(:get, "#{BASE_URL}/works/OL1W").to_raise(Faraday::ConnectionFailed)

        assert_raises(Books::OpenLibrary::Exceptions::NetworkError) { @client.get("/works/OL1W") }
      end

      test "malformed JSON on a 200 response raises ParseError" do
        stub_request(:get, "#{BASE_URL}/works/OL1W").to_return(status: 200, body: "not json")

        error = assert_raises(Books::OpenLibrary::Exceptions::ParseError) { @client.get("/works/OL1W") }

        assert_equal "not json", error.response_body
      end

      test "post sends a JSON body with a JSON content type and parses the response" do
        stub_request(:post, "#{BASE_URL}/resolve")
          .with(
            body: {title: "Dune", author: "Frank Herbert"}.to_json,
            headers: {"Content-Type" => "application/json"}
          )
          .to_return(status: 200, body: '{"match":true}')

        result = @client.post("/resolve", {title: "Dune", author: "Frank Herbert"})

        assert result[:success]
        assert_equal({"match" => true}, result[:data])
        assert_equal "/resolve", result[:metadata][:path]
      end

      test "five consecutive 404s do not open the breaker; the sixth request is still made" do
        url = "#{BASE_URL}/works/missing"
        stub_request(:get, url).to_return(status: 404, body: "not found")

        6.times do
          assert_raises(Books::OpenLibrary::Exceptions::NotFoundError) { @client.get("/works/missing") }
        end

        assert_not @breaker.open?
        assert_requested :get, url, times: 6
      end

      test "five consecutive 500s open the breaker; the sixth call raises CircuitOpenError and makes no request" do
        failing_url = "#{BASE_URL}/works/OL1W"
        stub_request(:get, failing_url).to_return(status: 500, body: "boom")

        5.times do
          assert_raises(Books::OpenLibrary::Exceptions::ServerError) { @client.get("/works/OL1W") }
        end

        assert @breaker.open?

        # /authors/OL1A has no stub registered: if the open circuit failed to
        # short-circuit and the request actually went out, WebMock would raise
        # its own NetConnectNotAllowedError instead of CircuitOpenError.
        assert_raises(Books::OpenLibrary::Exceptions::CircuitOpenError) { @client.get("/authors/OL1A") }

        assert_not_requested :get, "#{BASE_URL}/authors/OL1A"
        assert_requested :get, failing_url, times: 5
      end

      test "the connection defaults to config.timeout and open_timeout" do
        assert_equal @config.timeout, @client.connection.options.timeout
        assert_equal @config.open_timeout, @client.connection.options.open_timeout
      end

      test "a per-call timeout overrides the connection default for that request only" do
        fake_request = FakeFaradayRequest.new
        fake_response = FakeFaradayResponse.new(200, "{}")

        @client.connection.expects(:get).with("/works/OL1W").yields(fake_request).returns(fake_response)

        @client.get("/works/OL1W", {}, timeout: 30)

        assert_equal 30, fake_request.options.timeout
      end
    end
  end
end

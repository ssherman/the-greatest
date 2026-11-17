# frozen_string_literal: true

require "test_helper"
require "ostruct"
require "logger"
require "stringio"

module PageFetcher
  class ClientTest < ActiveSupport::TestCase
    BASE_URL = "http://page-fetcher.test:8081"
    FETCH_URL = "#{BASE_URL}/fetch"
    FILE_FETCH_URL = "#{BASE_URL}/fetch_file"
    FILE_URL = "https://us.macmillan.com/sitemaps/sitemap-products.1.xml.gz"
    PAGE_URL = "https://www.goodreads.com/book/show/4671.The_Great_Gatsby"

    # WebMock cannot observe Faraday's per-request read timeout (a Net::HTTP
    # socket setting), so that test stubs the connection instead, as the Open
    # Library base client test does.
    class FakeFaradayRequest
      attr_accessor :headers, :body, :options

      def initialize
        @headers = {}
        @options = OpenStruct.new
      end
    end

    FakeFaradayResponse = Struct.new(:status, :body)

    def setup
      @config = PageFetcher::Configuration.new(base_url: BASE_URL)
      @breaker = Books::OpenLibrary::CircuitBreaker.new(
        key: "test:page_fetcher", failure_threshold: 5, cooldown: 60, redis: Books::OpenLibrary::FakeRedis.new
      )
      @client = PageFetcher::Client.new(config: @config, breaker: @breaker)
    end

    def page_body(**overrides)
      {
        url: PAGE_URL, final_url: PAGE_URL, status: 200, title: "The Great Gatsby",
        html: "<html>Gatsby</html>", selector_found: nil, elapsed_ms: 4120, fetched_at: "2026-09-26T18:02:11Z"
      }.merge(overrides).to_json
    end

    FILE_BYTES = "\x1F\x8B\x08\x00FILE_SENTINEL\xFF".b

    def file_body(**overrides)
      {
        url: FILE_URL, final_url: FILE_URL, status: 200, content_type: "application/octet-stream",
        body_base64: Base64.strict_encode64(FILE_BYTES), size_bytes: FILE_BYTES.bytesize,
        elapsed_ms: 812, fetched_at: "2026-11-17T18:02:11Z"
      }.merge(overrides).to_json
    end

    def error_body(code, detail = "what happened")
      {error: code, detail: detail}.to_json
    end

    test "a 200 returns the page" do
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body)

      page = @client.fetch(PAGE_URL)

      assert_instance_of PageFetcher::Page, page
      assert_equal [200, "The Great Gatsby", "<html>Gatsby</html>"], [page.status, page.title, page.html]
      assert_equal Time.utc(2026, 9, 26, 18, 2, 11), page.fetched_at
    end

    test "posts the url, wait condition and timeout and omits a missing selector" do
      stub_request(:post, FETCH_URL)
        .with(body: {"url" => PAGE_URL, "wait_until" => "load", "timeout_ms" => 30_000},
          headers: {"Content-Type" => "application/json"})
        .to_return(status: 200, body: page_body)

      @client.fetch(PAGE_URL)

      # An exact body hash: a stray wait_for_selector key would not match the stub.
      assert_requested :post, FETCH_URL, times: 1
    end

    test "sends the selector when one is given and never a blank one" do
      stub_request(:post, FETCH_URL)
        .with(body: {"url" => PAGE_URL, "wait_until" => "networkidle", "wait_for_selector" => "h1", "timeout_ms" => 45_000})
        .to_return(status: 200, body: page_body(selector_found: true))

      assert @client.fetch(PAGE_URL, wait_until: "networkidle", wait_for_selector: "h1", timeout_ms: 45_000).selector_found

      blank_stub = stub_request(:post, FETCH_URL)
        .with(body: {"url" => PAGE_URL, "wait_until" => "load", "timeout_ms" => 30_000})
        .to_return(status: 200, body: page_body)

      @client.fetch(PAGE_URL, wait_for_selector: "")

      assert_requested blank_stub
    end

    test "sends the configured User-Agent and a JSON Accept header" do
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body)

      @client.fetch(PAGE_URL)

      assert_requested :post, FETCH_URL, headers: {"User-Agent" => @config.user_agent, "Accept" => "application/json"}
    end

    test "an upstream 403 and a selector that never appeared are successful fetches" do
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body(status: 403, selector_found: false))

      page = @client.fetch(PAGE_URL, wait_for_selector: "h1")

      assert_equal [403, false], [page.status, page.selector_found]
    end

    test "a 422 raises ClientError and five of them leave the breaker closed" do
      stub_request(:post, FETCH_URL).to_return(status: 422, body: '{"detail":[{"loc":["body","wait"]}]}')

      6.times do
        error = assert_raises(PageFetcher::Exceptions::ClientError) { @client.fetch(PAGE_URL) }
        assert_equal 422, error.status_code
      end

      assert_not @breaker.open?
      assert_requested :post, FETCH_URL, times: 6
    end

    test "a 400 carries the service's error code" do
      stub_request(:post, FETCH_URL).to_return(status: 400, body: error_body("invalid_selector", "Unexpected token"))

      error = assert_raises(PageFetcher::Exceptions::ClientError) { @client.fetch(PAGE_URL, wait_for_selector: "div[[") }

      assert_equal "invalid_selector", error.error_code
      assert_match(/Unexpected token/, error.message)
    end

    test "upstream failures raise UpstreamError and never trip the breaker" do
      %w[upstream_unreachable html_too_large].each do |code|
        stub_request(:post, FETCH_URL).to_return(status: 502, body: error_body(code))

        6.times do
          error = assert_raises(PageFetcher::Exceptions::UpstreamError) { @client.fetch(PAGE_URL) }
          assert_equal code, error.error_code
        end

        assert_not @breaker.open?
      end
    end

    test "service failures raise ServerError" do
      {502 => "browser_error", 503 => "browser_unavailable", 504 => "navigation_timeout"}.each do |status, code|
        stub_request(:post, FETCH_URL).to_return(status: status, body: error_body(code))

        error = assert_raises(PageFetcher::Exceptions::ServerError) { @client.fetch(PAGE_URL) }

        assert_equal [status, code], [error.status_code, error.error_code]
        @breaker.reset!
      end
    end

    test "a 502 whose body is not the service's is a ServerError" do
      stub_request(:post, FETCH_URL).to_return(status: 502, body: "<html>Bad Gateway</html>")

      error = assert_raises(PageFetcher::Exceptions::ServerError) { @client.fetch(PAGE_URL) }

      assert_nil error.error_code
    end

    test "five browser errors open the circuit; the sixth call raises PageFetcher's CircuitOpenError and makes no request" do
      stub_request(:post, FETCH_URL).to_return(status: 502, body: error_body("browser_error"))

      5.times { assert_raises(PageFetcher::Exceptions::ServerError) { @client.fetch(PAGE_URL) } }
      assert @breaker.open?

      error = assert_raises(PageFetcher::Exceptions::CircuitOpenError) { @client.fetch(PAGE_URL) }

      assert_kind_of PageFetcher::Exceptions::Error, error
      assert_requested :post, FETCH_URL, times: 5
    end

    test "a timeout raises TimeoutError and counts against the breaker" do
      stub_request(:post, FETCH_URL).to_raise(Faraday::TimeoutError)

      5.times { assert_raises(PageFetcher::Exceptions::TimeoutError) { @client.fetch(PAGE_URL) } }

      assert @breaker.open?
    end

    test "a connection failure raises NetworkError and counts against the breaker" do
      stub_request(:post, FETCH_URL).to_raise(Faraday::ConnectionFailed)

      5.times { assert_raises(PageFetcher::Exceptions::NetworkError) { @client.fetch(PAGE_URL) } }

      assert @breaker.open?
    end

    test "an unparseable 200 raises ParseError and counts against the breaker" do
      # Five bodies, so the fifth ParseError is the one that opens the circuit.
      bodies = ["not json", "null", "[1, 2]", page_body.sub('"html"', '"body"'), page_body(fetched_at: "yesterday")]
      bodies.each do |body|
        stub_request(:post, FETCH_URL).to_return(status: 200, body: body)

        assert_raises(PageFetcher::Exceptions::ParseError) { @client.fetch(PAGE_URL) }
      end

      assert @breaker.open?
    end

    test "the read timeout is the budget plus the padding" do
      fake_request = FakeFaradayRequest.new
      @client.connection.expects(:post).with("/fetch").yields(fake_request).returns(FakeFaradayResponse.new(200, page_body))

      @client.fetch(PAGE_URL, timeout_ms: 45_000)

      assert_in_delta 55.0, fake_request.options.timeout
    end

    test "the connection uses the configured open timeout" do
      config = PageFetcher::Configuration.new(base_url: BASE_URL, open_timeout: 7)
      client = PageFetcher::Client.new(config: config, breaker: @breaker)

      assert_equal 7, client.connection.options.open_timeout
    end

    test "builds a default configuration and breaker when none is given" do
      client = PageFetcher::Client.new

      assert_instance_of PageFetcher::Configuration, client.config
      assert_instance_of Books::OpenLibrary::CircuitBreaker, client.breaker
    end

    test "a 200 missing a required key is a ParseError with no response body and the KeyError message" do
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body.sub('"final_url"', '"other_url"'))

      error = assert_raises(PageFetcher::Exceptions::ParseError) { @client.fetch(PAGE_URL) }

      assert_nil error.response_body
      assert_equal 'Failed to parse the fetch response: key not found: "final_url"', error.message
    end

    test "a non-JSON 200 body is a ParseError with no response body and a fixed message, never the body" do
      stub_request(:post, FETCH_URL).to_return(status: 200, body: "<html>not json at all</html>")

      error = assert_raises(PageFetcher::Exceptions::ParseError) { @client.fetch(PAGE_URL) }

      assert_nil error.response_body
      assert_equal "The fetch response is not JSON", error.message
    end

    test "the page HTML never reaches the Faraday logger" do
      # page_body serializes with ActiveSupport's to_json, which escapes < and
      # >, so a literal "<...>" substring would never appear in the log even
      # if the whole body were logged. The sentinel below has no characters
      # to_json escapes, so it stays intact through JSON encoding and would
      # show up verbatim if the body reached the logger.
      io = StringIO.new
      config = PageFetcher::Configuration.new(base_url: BASE_URL, logger: Logger.new(io))
      client = PageFetcher::Client.new(config: config, breaker: @breaker)
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body(html: "<p>HTML_SENTINEL</p>"))

      client.fetch(PAGE_URL)

      assert_includes io.string, "Status 200" # positive control: the logger did write something
      refute_includes io.string, "HTML_SENTINEL"
    end

    test "fetch_file returns the file's bytes" do
      stub_request(:post, FILE_FETCH_URL).to_return(status: 200, body: file_body)

      file = @client.fetch_file(FILE_URL)

      assert_instance_of PageFetcher::FileResponse, file
      assert_equal [200, "application/octet-stream", FILE_BYTES], [file.status, file.content_type, file.body]
    end

    test "fetch_file posts the url and timeout and omits a missing page_url" do
      stub_request(:post, FILE_FETCH_URL)
        .with(body: {"url" => FILE_URL, "timeout_ms" => 30_000}, headers: {"Content-Type" => "application/json"})
        .to_return(status: 200, body: file_body)

      @client.fetch_file(FILE_URL)

      assert_requested :post, FILE_FETCH_URL, times: 1
    end

    test "fetch_file sends page_url when given and never a blank one" do
      stub_request(:post, FILE_FETCH_URL)
        .with(body: {"url" => FILE_URL, "timeout_ms" => 30_000, "page_url" => "https://us.macmillan.com/"})
        .to_return(status: 200, body: file_body)

      @client.fetch_file(FILE_URL, page_url: "https://us.macmillan.com/")

      blank_stub = stub_request(:post, FILE_FETCH_URL)
        .with(body: {"url" => FILE_URL, "timeout_ms" => 30_000})
        .to_return(status: 200, body: file_body)

      @client.fetch_file(FILE_URL, page_url: "")

      assert_requested blank_stub
    end

    test "a site 403 for the file is a successful fetch" do
      stub_request(:post, FILE_FETCH_URL).to_return(status: 200, body: file_body(status: 403))

      assert_equal 403, @client.fetch_file(FILE_URL).status
    end

    test "file_too_large raises UpstreamError and never trips the breaker" do
      stub_request(:post, FILE_FETCH_URL).to_return(status: 502, body: error_body("file_too_large"))

      6.times do
        error = assert_raises(PageFetcher::Exceptions::UpstreamError) { @client.fetch_file(FILE_URL) }
        assert_equal "file_too_large", error.error_code
      end

      assert_not @breaker.open?
    end

    test "fetch_file maps 4xx and 5xx like fetch" do
      {400 => ["invalid_url", PageFetcher::Exceptions::ClientError],
       502 => ["browser_error", PageFetcher::Exceptions::ServerError],
       503 => ["browser_unavailable", PageFetcher::Exceptions::ServerError]}.each do |status, (code, klass)|
        stub_request(:post, FILE_FETCH_URL).to_return(status: status, body: error_body(code))

        error = assert_raises(klass) { @client.fetch_file(FILE_URL) }

        assert_equal [status, code], [error.status_code, error.error_code]
      end
    end

    test "five browser errors on fetch_file open the circuit that fetch shares" do
      stub_request(:post, FILE_FETCH_URL).to_return(status: 502, body: error_body("browser_error"))

      5.times { assert_raises(PageFetcher::Exceptions::ServerError) { @client.fetch_file(FILE_URL) } }

      assert_raises(PageFetcher::Exceptions::CircuitOpenError) { @client.fetch(PAGE_URL) }
      assert_not_requested :post, FETCH_URL
    end

    test "an unparseable fetch_file 200 is a ParseError with no response body" do
      bodies = ["FILE_SENTINEL not json", "[1, 2]", file_body.sub('"body_base64"', '"other"'),
        file_body(body_base64: "!!FILE_SENTINEL!!")]
      bodies.each do |body|
        stub_request(:post, FILE_FETCH_URL).to_return(status: 200, body: body)

        error = assert_raises(PageFetcher::Exceptions::ParseError) { @client.fetch_file(FILE_URL) }

        assert_nil error.response_body
        refute_includes error.message, "FILE_SENTINEL"
      end
    end

    test "the fetch_file read timeout is the budget plus the padding" do
      fake_request = FakeFaradayRequest.new
      @client.connection.expects(:post).with("/fetch_file").yields(fake_request).returns(FakeFaradayResponse.new(200, file_body))

      @client.fetch_file(FILE_URL, timeout_ms: 45_000)

      assert_in_delta 55.0, fake_request.options.timeout
    end

    test "the file body never reaches the Faraday logger" do
      io = StringIO.new
      config = PageFetcher::Configuration.new(base_url: BASE_URL, logger: Logger.new(io))
      client = PageFetcher::Client.new(config: config, breaker: @breaker)
      encoded = Base64.strict_encode64("FILE_SENTINEL_BYTES")
      stub_request(:post, FILE_FETCH_URL).to_return(status: 200, body: file_body(body_base64: encoded, size_bytes: 19))

      client.fetch_file(FILE_URL)

      assert_includes io.string, "Status 200"
      refute_includes io.string, encoded
      refute_includes io.string, "FILE_SENTINEL"
    end

    def access
      CloudflareAccess::Credentials.new(client_id: "id.access", client_secret: "s3cret")
    end

    test "sends the Cloudflare Access headers when configured" do
      config = PageFetcher::Configuration.new(base_url: BASE_URL, access: access)
      client = PageFetcher::Client.new(config: config, breaker: @breaker)
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body)

      client.fetch(PAGE_URL)

      assert_requested :post, FETCH_URL, headers: {"CF-Access-Client-Id" => "id.access", "CF-Access-Client-Secret" => "s3cret"}
    end

    test "sends no Access headers when not configured" do
      none = CloudflareAccess::Credentials.new(client_id: nil, client_secret: nil)
      client = PageFetcher::Client.new(config: PageFetcher::Configuration.new(base_url: BASE_URL, access: none), breaker: @breaker)
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body)

      client.fetch(PAGE_URL)

      assert_requested(:post, FETCH_URL) { |req| !req.headers.key?("Cf-Access-Client-Id") && !req.headers.key?("Cf-Access-Client-Secret") }
    end

    test "never writes the Access secret to the request log" do
      log = StringIO.new
      config = PageFetcher::Configuration.new(base_url: BASE_URL, access: access, logger: Logger.new(log))
      client = PageFetcher::Client.new(config: config, breaker: @breaker)
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body)

      client.fetch(PAGE_URL)

      assert_includes log.string, "CF-Access-Client-Id"
      assert_not_includes log.string, "s3cret"
    end

    test "never writes the Access session cookie to the request log" do
      log = StringIO.new
      config = PageFetcher::Configuration.new(base_url: BASE_URL, access: access, logger: Logger.new(log))
      client = PageFetcher::Client.new(config: config, breaker: @breaker)
      stub_request(:post, FETCH_URL).to_return(status: 200, body: page_body,
        headers: {"Set-Cookie" => "CF_Authorization=eyJhbGciOiJSUzI1NiJ9.SESSION_JWT; Expires=Mon, 05 Oct 2026 18:59:17 GMT; Path=/; Secure; HttpOnly"})

      client.fetch(PAGE_URL)

      assert_includes log.string, "CF_Authorization=[FILTERED]; Expires"
      assert_not_includes log.string, "SESSION_JWT"
    end
  end
end

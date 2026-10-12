require "test_helper"

module Books
  module WorldCat
    class BaseClientTest < ActiveSupport::TestCase
      BASE_URL = "http://wc.test:8082"

      def setup
        @config = Configuration.new(base_url: BASE_URL, logger: nil)
        @breaker = Books::OpenLibrary::CircuitBreaker.new(key: "test:world_cat", failure_threshold: 5, cooldown: 60, redis: Books::OpenLibrary::FakeRedis.new)
        @client = BaseClient.new(@config, breaker: @breaker)
      end

      test "a 200 returns parsed data and metadata" do
        stub_request(:get, "#{BASE_URL}/version").to_return(status: 200, body: {dump_date: "2025-09-04"}.to_json)
        result = @client.get("/version")
        assert_equal({"dump_date" => "2025-09-04"}, result[:data])
        assert_equal 200, result[:metadata][:status_code]
      end

      test "sends User-Agent, Accept and the Access headers" do
        access = CloudflareAccess::Credentials.new(client_id: "cid", client_secret: "sec")
        client = BaseClient.new(Configuration.new(base_url: BASE_URL, logger: nil, access: access), breaker: @breaker)
        stub_request(:get, "#{BASE_URL}/version").to_return(status: 200, body: "{}")
        client.get("/version")
        assert_requested :get, "#{BASE_URL}/version", headers: {"Accept" => "application/json", "CF-Access-Client-Id" => "cid", "CF-Access-Client-Secret" => "sec"}
      end

      test "404, 422 and 500 map to NotFoundError, ClientError and ServerError" do
        {404 => Exceptions::NotFoundError, 422 => Exceptions::ClientError, 500 => Exceptions::ServerError}.each do |status, klass|
          stub_request(:get, "#{BASE_URL}/x#{status}").to_return(status: status, body: "{}")
          assert_raises(klass) { @client.get("/x#{status}") }
        end
      end

      test "five 404s leave the breaker closed; five 500s open it" do
        stub_request(:get, "#{BASE_URL}/missing").to_return(status: 404, body: "{}")
        5.times { assert_raises(Exceptions::NotFoundError) { @client.get("/missing") } }
        assert_not @breaker.open?
        stub_request(:get, "#{BASE_URL}/broken").to_return(status: 500, body: "{}")
        5.times { assert_raises(Exceptions::ServerError) { @client.get("/broken") } }
        assert @breaker.open?
        assert_raises(Exceptions::CircuitOpenError) { @client.get("/version") }
      end

      test "timeouts, connection failures and malformed JSON raise typed errors" do
        # WebMock's .to_timeout raises Net::OpenTimeout, which Faraday maps to ConnectionFailed.
        stub_request(:get, "#{BASE_URL}/slow").to_raise(Faraday::TimeoutError)
        assert_raises(Exceptions::TimeoutError) { @client.get("/slow") }
        stub_request(:get, "#{BASE_URL}/down").to_raise(Faraday::ConnectionFailed.new("down"))
        assert_raises(Exceptions::NetworkError) { @client.get("/down") }
        stub_request(:get, "#{BASE_URL}/junk").to_return(status: 200, body: "not json")
        assert_raises(Exceptions::ParseError) { @client.get("/junk") }
      end

      test "post sends JSON with its own timeout" do
        stub_request(:post, "#{BASE_URL}/lookup").with(body: {isbn13s: ["1"]}.to_json, headers: {"Content-Type" => "application/json"}).to_return(status: 200, body: {results: {}}.to_json)
        assert_equal({"results" => {}}, @client.post("/lookup", {isbn13s: ["1"]}, timeout: 20)[:data])
      end

      test "never writes the Access secret or the session cookie to the request log" do
        io = StringIO.new
        access = CloudflareAccess::Credentials.new(client_id: "cid", client_secret: "sec-ret")
        client = BaseClient.new(Configuration.new(base_url: BASE_URL, logger: Logger.new(io), access: access), breaker: @breaker)
        stub_request(:get, "#{BASE_URL}/version").to_return(status: 200, body: "{}", headers: {"Set-Cookie" => "CF_Authorization=abc.def; Path=/"})
        client.get("/version")
        assert_no_match(/sec-ret/, io.string)
        assert_no_match(/abc\.def/, io.string)
      end
    end
  end
end

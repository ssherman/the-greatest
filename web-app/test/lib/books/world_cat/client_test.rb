require "test_helper"

module Books
  module WorldCat
    class ClientTest < ActiveSupport::TestCase
      BASE_URL = "http://wc.test:8082"

      def setup
        @breaker = Books::OpenLibrary::CircuitBreaker.new(key: "test:world_cat:client", failure_threshold: 5, cooldown: 60, redis: Books::OpenLibrary::FakeRedis.new)
        @client = Client.new(config: Configuration.new(base_url: BASE_URL, logger: nil), breaker: @breaker)
      end

      def record_hash(oclc, genre: "Fiction")
        {"oclc" => oclc, "title" => "T", "genre" => genre, "subjects" => ["S"], "isbn13s" => ["9780735211292"], "holdings" => nil}
      end

      test "#record_by_isbn returns records for a hit and an empty array for a miss" do
        stub_request(:get, "#{BASE_URL}/isbns/9780735211292").to_return(status: 200, body: {isbn13: "9780735211292", records: [record_hash(1)]}.to_json)
        stub_request(:get, "#{BASE_URL}/isbns/9783161484100").to_return(status: 200, body: {isbn13: "9783161484100", records: []}.to_json)
        assert_equal [1], @client.record_by_isbn("9780735211292").map(&:oclc)
        assert_equal [], @client.record_by_isbn("9783161484100")
      end

      test "#record_by_oclc returns nil on 404 and the record otherwise" do
        stub_request(:get, "#{BASE_URL}/oclc/5").to_return(status: 404, body: {detail: "unknown"}.to_json)
        stub_request(:get, "#{BASE_URL}/oclc/1").to_return(status: 200, body: record_hash(1).merge("redirected_from" => 9).to_json)
        assert_nil @client.record_by_oclc(5)
        assert_equal 9, @client.record_by_oclc(1).redirected_from
      end

      test "#lookup chunks at 500, keys every request as given, and uses the batch timeout" do
        isbns = Array.new(501) { |i| "978#{i.to_s.rjust(10, "0")}" }
        stub_request(:post, "#{BASE_URL}/lookup").with(body: {isbn13s: isbns.first(500)}.to_json)
          .to_return(status: 200, body: {results: isbns.first(500).to_h { |i| [i, [record_hash(1)]] }}.to_json)
        stub_request(:post, "#{BASE_URL}/lookup").with(body: {isbn13s: isbns.last(1)}.to_json)
          .to_return(status: 200, body: {results: {isbns.last => []}}.to_json)

        result = @client.lookup(isbns)

        assert_equal 501, result.size
        assert_equal [1], result[isbns.first].map(&:oclc)
        assert_equal [], result[isbns.last]
        assert_requested :post, "#{BASE_URL}/lookup", times: 2
      end

      test "#lookup with no ISBNs makes no request" do
        assert_equal({}, @client.lookup([]))
        assert_not_requested :post, "#{BASE_URL}/lookup"
      end

      test "#version returns the symbolised version hash" do
        stub_request(:get, "#{BASE_URL}/version").to_return(status: 200, body: {dump_date: "2025-09-04", gates_passed: true}.to_json)
        assert_equal "2025-09-04", @client.version[:dump_date]
      end
    end
  end
end

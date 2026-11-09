# frozen_string_literal: true

require "test_helper"

module Wikidata
  class ClientTest < ActiveSupport::TestCase
    BASE = "http://127.0.0.1:8083"

    def setup
      breaker = Books::OpenLibrary::CircuitBreaker.new(key: "test:wikidata:client", failure_threshold: 5, cooldown: 60,
        redis: Books::OpenLibrary::FakeRedis.new)
      @client = Client.new(service: Service.new(Configuration.new(base_url: BASE, logger: nil), breaker: breaker))
    end

    def fixture(name) = file_fixture("wikidata/#{name}").read

    def json_response(body, status: 200) = {status: status, body: body, headers: {"Content-Type" => "application/json"}}

    def request_body(request) = JSON.parse(request.body)

    test "entities posts the ids to /items and keys each entity by the id asked for" do
      stub = stub_request(:post, "#{BASE}/items").with { |r| request_body(r) == {"ids" => ["Q7243"]} }
        .to_return(json_response(fixture("items_Q7243.json")))

      found = @client.entities(["Q7243"])

      assert_requested stub
      assert_equal ["Q7243"], found.keys
      assert_equal "Leo Tolstoy", found["Q7243"].dig("labels", "en", "value")
      assert_equal "Leo Tolstoy", found["Q7243"].dig("sitelinks", "enwiki", "title")
      assert_equal "2026-11-05", @client.dump_date
    end

    test "entities records not_kept ids and leaves them and missing ids out of the answer" do
      body = {items: {"Q2" => {"id" => "Q7243", "dump_date" => "2026-11-05"}}, not_kept: ["Q1"], missing: ["Q3"]}.to_json
      stub_request(:post, "#{BASE}/items").to_return(json_response(body))

      found = @client.entities(["Q1", "Q2", "Q3"])

      assert_equal ["Q2"], found.keys
      assert_equal Set["Q1"], @client.not_kept
      assert_equal "Q7243", found["Q2"]["id"]
    end

    test "entities resets not_kept on each call" do
      stub_request(:post, "#{BASE}/items").to_return(json_response({items: {}, not_kept: ["Q1"], missing: []}.to_json))
      @client.entities(["Q1"])
      stub_request(:post, "#{BASE}/items").to_return(json_response({items: {}, not_kept: [], missing: []}.to_json))

      @client.entities(["Q1"])

      assert_empty @client.not_kept
    end

    test "entities sends at most 50 ids per request, only valid QIDs, and nothing at all for none" do
      ids = (1..51).map { |n| "Q#{n}" } + ["Q0", "Q07", "bad", "P5"]
      stub = stub_request(:post, "#{BASE}/items").to_return(json_response({items: {}, not_kept: [], missing: []}.to_json))

      @client.entities(ids)
      @client.entities([])

      assert_requested stub, times: 2
      assert_requested(:post, "#{BASE}/items") { |r| request_body(r)["ids"].size == 50 }
      assert_requested(:post, "#{BASE}/items") { |r| request_body(r)["ids"] == ["Q51"] }
    end

    test "search asks /names for ten and returns id, label and description" do
      stub = stub_request(:get, "#{BASE}/names").with(query: {q: "Leo Tolstoy", limit: "10"})
        .to_return(json_response(fixture("names_leo_tolstoy.json")))

      hits = @client.search("Leo Tolstoy")

      assert_requested stub
      assert_equal "Q7243", hits.first["id"]
      assert_equal "Leo Tolstoy", hits.first["label"]
      assert hits.all? { |hit| hit.keys.sort == %w[description id label] }
    end

    test "search returns nothing, without a request, for a blank name" do
      assert_equal [], @client.search(nil)
      assert_equal [], @client.search("  ")
      assert_not_requested :get, /#{BASE}/o
    end

    test "by_statements posts every pair to /by-external-id with the limit and returns ids" do
      stub = stub_request(:post, "#{BASE}/by-external-id")
        .with { |r| request_body(r) == {"pairs" => [["P648", "OL26783A"], ["P214", "96987389"]], "limit" => 10} }
        .to_return(json_response(fixture("by_external_id_tolstoy.json")))

      assert_equal ["Q7243"], @client.by_statements([["P648", "OL26783A"], ["P214", "96987389"]])
      assert_requested stub
    end

    test "by_statements sends the given limit" do
      stub = stub_request(:post, "#{BASE}/by-external-id").with { |r| request_body(r)["limit"] == 50 }
        .to_return(json_response(fixture("by_external_id_tolstoy.json")))

      @client.by_statements([["P648", "OL26783A"]], limit: 50)

      assert_requested stub
    end

    test "by_statements drops malformed pairs and sends nothing when none remain" do
      assert_equal [], @client.by_statements([["name", "x"], ["P648", ""]])
      assert_equal [], @client.by_statements([])
      assert_not_requested :post, "#{BASE}/by-external-id"
    end

    test "by_statements drops values over the service's 200 characters and caps the pairs at 500" do
      stub = stub_request(:post, "#{BASE}/by-external-id")
        .with { |r|
        body = request_body(r)
        body["pairs"].size == 500 && body["pairs"].none? { |_, value| value.length > 200 }
      }
        .to_return(json_response(fixture("by_external_id_tolstoy.json")))
      pairs = [["P648", "x" * 201]] + (1..600).map { |i| ["P648", "OL#{i}A"] }

      @client.by_statements(pairs)

      assert_requested stub
    end

    test "works makes one /linked-from request and groups each author's titles once" do
      stub = stub_request(:post, "#{BASE}/linked-from")
        .with { |r| request_body(r) == {"targets" => ["Q7243"], "properties" => %w[P50 P800], "exclude_types" => ["Q3331189"], "limit" => 5000} }
        .to_return(json_response(fixture("linked_from_Q7243.json")))

      works = @client.works(["Q7243"])

      assert_requested stub, times: 1
      assert_equal({"Q7243" => ["War and Peace", "Anna Karenina"]}, works)
      assert_equal({}, @client.works([]))
    end

    test "works logs a warning when the answer was truncated" do
      stub_request(:post, "#{BASE}/linked-from").to_return(json_response({rows: [["Q7243", "Q1", "One"]], truncated: true}.to_json))
      Rails.logger.expects(:warn).with { |message| message.include?("#{Client::WORKS_ROW_LIMIT}-row limit") }.once

      @client.works(["Q7243"])
    end

    test "works logs nothing when the answer was not truncated" do
      stub_request(:post, "#{BASE}/linked-from").to_return(json_response(fixture("linked_from_Q7243.json")))
      Rails.logger.expects(:warn).never

      @client.works(["Q7243"])
    end

    test "work_items returns id and label pairs per author, a repeated work once" do
      stub_request(:post, "#{BASE}/linked-from").to_return(json_response(fixture("linked_from_Q7243.json")))

      assert_equal({"Q7243" => [{"id" => "Q161531", "label" => "War and Peace"}, {"id" => "Q23", "label" => "Anna Karenina"}]},
        @client.work_items(["Q7243"]))
    end

    test "work_items skips rows with a blank label and makes no request for no input" do
      stub_request(:post, "#{BASE}/linked-from").to_return(json_response({rows: [["Q1", "Q10", ""], ["Q2", "Q20", "Twenty"]], truncated: false}.to_json))

      assert_equal({"Q2" => [{"id" => "Q20", "label" => "Twenty"}]}, @client.work_items(["Q1", "Q2"]))
      assert_equal({}, @client.work_items([]))
    end

    test "country_codes reads the best-rank P297 and the English label, else the all-languages one" do
      stub = stub_request(:post, "#{BASE}/items").with { |r| request_body(r)["ids"] == %w[Q30 Q34266 Q159 Q999 Q998] }
        .to_return(json_response(fixture("items_countries.json")))

      codes = @client.country_codes(%w[Q30 Q34266 Q159 Q999 Q998])

      assert_requested stub
      assert_equal({"code" => "US", "label" => "United States"}, codes["Q30"])
      assert_equal({"code" => nil, "label" => "Russian Empire"}, codes["Q34266"])
      assert_equal({"code" => "SU", "label" => "Russia"}, codes["Q159"])
      assert_equal %w[Q30 Q34266 Q159], codes.keys
    end

    test "country_codes takes the normal code when none is preferred and ignores a malformed one" do
      claim = ->(value, rank) { {"rank" => rank, "mainsnak" => {"datavalue" => {"value" => value}}} }
      entity = {"id" => "Q1", "labels" => {}, "claims" => {"P297" => [claim.call("xx1", "normal"), claim.call("DE", "normal"), claim.call("ZZ", "deprecated")]}}
      stub_request(:post, "#{BASE}/items").to_return(json_response({items: {"Q1" => entity}}.to_json))

      assert_equal({"code" => "DE", "label" => nil}, @client.country_codes(["Q1"])["Q1"])
    end

    test "labels posts to /labels and returns the English label, else the all-languages one" do
      stub = stub_request(:post, "#{BASE}/labels").with { |r| request_body(r)["ids"] == %w[Q30 Q1 Q5] }
        .to_return(json_response(fixture("labels_countries.json")))

      assert_equal({"Q30" => "United States", "Q34266" => "Russian Empire", "Q36180" => "writer", "Q1" => "Victor Hugo"},
        @client.labels(%w[Q30 Q1 Q5]))
      assert_requested stub
    end

    test "labels makes no request for no valid ids" do
      assert_equal({}, @client.labels(["nope"]))
      assert_not_requested :post, "#{BASE}/labels"
    end

    test "a connection failure raises Unavailable, which is a RateLimited asking for 300 seconds" do
      stub_request(:post, "#{BASE}/items").to_raise(Faraday::ConnectionFailed.new("refused"))

      error = assert_raises(Exceptions::Unavailable) { @client.entities(["Q1"]) }

      assert_kind_of ::Wikimedia::Exceptions::RateLimited, error
      assert_equal 300, error.retry_after
    end

    test "a timeout raises Unavailable" do
      stub_request(:get, "#{BASE}/names").with(query: hash_including(q: "x")).to_timeout

      assert_raises(Exceptions::Unavailable) { @client.search("x") }
    end

    test "a 500 raises Unavailable" do
      stub_request(:post, "#{BASE}/labels").to_return(status: 500, body: "{}")

      assert_raises(Exceptions::Unavailable) { @client.labels(["Q1"]) }
    end

    test "a 422 raises ServiceError, which is not rate limited" do
      stub_request(:post, "#{BASE}/items").to_return(json_response({detail: "bad"}.to_json, status: 422))

      error = assert_raises(Exceptions::ServiceError) { @client.entities(["Q1"]) }

      assert_kind_of ::Wikimedia::Exceptions::Error, error
      assert_equal 422, error.status_code
    end

    test "a body that is not JSON raises ServiceError" do
      stub_request(:post, "#{BASE}/items").to_return(status: 200, body: "<html>")

      assert_raises(Exceptions::ServiceError) { @client.entities(["Q1"]) }
    end

    test "never calls wikidata.org, whatever the method" do
      stub_request(:any, /wikidata\.org/).to_raise("called wikidata.org")
      stub_request(:post, "#{BASE}/items").to_return(json_response(fixture("items_Q7243.json")))
      stub_request(:post, "#{BASE}/labels").to_return(json_response(fixture("labels_countries.json")))
      stub_request(:post, "#{BASE}/by-external-id").to_return(json_response(fixture("by_external_id_tolstoy.json")))
      stub_request(:post, "#{BASE}/linked-from").to_return(json_response(fixture("linked_from_Q7243.json")))
      stub_request(:get, "#{BASE}/names").with(query: hash_including({})).to_return(json_response(fixture("names_leo_tolstoy.json")))

      @client.entities(["Q7243"])
      @client.search("Leo Tolstoy")
      @client.by_statements([["P648", "OL1A"]])
      @client.works(["Q7243"])
      @client.work_items(["Q7243"])
      @client.country_codes(["Q7243"])
      @client.labels(["Q30"])

      assert_not_requested :any, /wikidata\.org/
    end
  end
end

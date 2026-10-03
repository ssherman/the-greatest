# frozen_string_literal: true

require "test_helper"

module Wikidata
  class ClientTest < ActiveSupport::TestCase
    API = "https://www.wikidata.org/w/api.php"
    SPARQL = "https://query.wikidata.org/sparql"

    def setup
      limiter = mock("limiter")
      limiter.stubs(:acquire!)
      @client = Client.new(http: ::Wikimedia::Http.new(limiter: limiter))
    end

    def fixture(name) = file_fixture("wikidata/#{name}").read

    def json_response(body) = {status: 200, body: body, headers: {"Content-Type" => "application/json"}}

    def sparql_query(request) = URI.decode_www_form(request.body).to_h["query"]

    test "entities fetches with wbgetentities and keys each entity by the requested id" do
      stub_request(:get, API).with(query: hash_including(action: "wbgetentities", ids: "Q7243"))
        .to_return(json_response(fixture("wbgetentities_Q7243.json")))

      found = @client.entities(["Q7243"])

      assert_equal ["Q7243"], found.keys
      assert_equal "Leo Tolstoy", found["Q7243"].dig("labels", "en", "value")
    end

    test "entities drops missing ids and keeps a redirected id under the id we asked for" do
      body = {entities: {
        "Q1" => {"id" => "Q1", "missing" => true},
        "Q2" => {"id" => "Q7243", "labels" => {}, "claims" => {}}
      }}.to_json
      stub_request(:get, API).with(query: hash_including(action: "wbgetentities", ids: "Q1|Q2")).to_return(json_response(body))

      found = @client.entities(["Q1", "Q2"])

      assert_equal ["Q2"], found.keys
      assert_equal "Q7243", found["Q2"]["id"]
    end

    test "entities asks for at most 50 ids per request and nothing at all for none" do
      ids = (1..51).map { |n| "Q#{n}" }
      stub = stub_request(:get, API).with(query: hash_including(action: "wbgetentities")).to_return(json_response({entities: {}}.to_json))

      @client.entities(ids)
      @client.entities([])

      assert_requested stub, times: 2
    end

    test "search asks for English items, ten at most, and returns id, label and description" do
      stub = stub_request(:get, API)
        .with(query: hash_including(action: "wbsearchentities", search: "Leo Tolstoy", language: "en", uselang: "en", type: "item", limit: "10"))
        .to_return(json_response(fixture("wbsearchentities_leo_tolstoy.json")))

      hits = @client.search("Leo Tolstoy")

      assert_requested stub
      assert_equal "Q7243", hits.first["id"]
      assert_equal "Leo Tolstoy", hits.first["label"]
      assert hits.all? { |hit| hit.keys.sort == %w[description id label] }
    end

    test "search returns nothing, without a request, for a blank name" do
      stub = stub_request(:get, API).with(query: hash_including(action: "wbsearchentities"))

      assert_equal [], @client.search(nil)
      assert_equal [], @client.search("")
      assert_equal [], @client.search("  ")
      assert_not_requested stub
    end

    test "by_statements ORs every pair into one haswbstatement search and returns item ids" do
      stub = stub_request(:get, API)
        .with(query: hash_including(action: "query", list: "search", srsearch: "haswbstatement:P648=OL26783A|P214=96987389", srnamespace: "0"))
        .to_return(json_response(fixture("haswbstatement_tolstoy.json")))

      ids = @client.by_statements([["P648", "OL26783A"], ["P214", "96987389"]])

      assert_requested stub
      assert_includes ids, "Q7243"
    end

    test "by_statements drops values that would break the search syntax, and sends nothing when none remain" do
      stub = stub_request(:get, API).with(query: hash_including(action: "query"))

      assert_equal [], @client.by_statements([["P213", "0000 0001"], ["P648", "OL1A\" OR"]])
      assert_equal [], @client.by_statements([])
      assert_not_requested stub
    end

    test "works posts one SPARQL query for every item and groups English titles per item" do
      stub = stub_request(:post, SPARQL)
        .with { |request| sparql_query(request).include?("wd:Q7243") && sparql_query(request).include?("wd:Q13442814") }
        .to_return(json_response(fixture("sparql_works_Q7243.json")))

      works = @client.works(["Q7243"])

      assert_requested stub
      assert_includes works["Q7243"], "War and Peace"
      assert_equal works["Q7243"].uniq, works["Q7243"]
      assert_equal({}, @client.works([]))
    end

    test "works logs a warning when the answer fills the row limit, since titles were cut" do
      rows = Array.new(Client::WORKS_ROW_LIMIT) do |index|
        {"author" => {"value" => "http://www.wikidata.org/entity/Q7243"}, "workLabel" => {"value" => "Work #{index}"}}
      end
      stub_request(:post, SPARQL).to_return(json_response({results: {bindings: rows}}.to_json))
      Rails.logger.expects(:warn).with { |message| message.include?("#{Client::WORKS_ROW_LIMIT}-row limit") }.once

      assert_equal Client::WORKS_ROW_LIMIT, @client.works(["Q7243"])["Q7243"].size
    end

    test "works logs nothing when the answer is under the row limit" do
      stub_request(:post, SPARQL).to_return(json_response(fixture("sparql_works_Q7243.json")))
      Rails.logger.expects(:warn).never

      @client.works(["Q7243"])
    end

    test "country_codes returns the ISO code and English label, and caches each country" do
      limiter = mock("limiter")
      limiter.stubs(:acquire!)
      client = Client.new(http: ::Wikimedia::Http.new(limiter: limiter), cache: ActiveSupport::Cache::MemoryStore.new)
      stub = stub_request(:post, SPARQL).to_return(json_response(fixture("sparql_country_codes.json")))

      codes = client.country_codes(["Q30", "Q34266"])
      again = client.country_codes(["Q30", "Q34266"])

      assert_equal "US", codes.dig("Q30", "code")
      assert_nil codes.dig("Q34266", "code")
      assert_equal "Russian Empire", codes.dig("Q34266", "label")
      assert_equal codes, again
      assert_requested stub, times: 1
    end

    test "country_codes ignores a code that is not two capital letters" do
      body = {results: {bindings: [
        {"country" => {"value" => "http://www.wikidata.org/entity/Q1"}, "code" => {"value" => "http://www.wikidata.org/.well-known/genid/abc"}, "countryLabel" => {"value" => "Somewhere"}}
      ]}}.to_json
      stub_request(:post, SPARQL).to_return(json_response(body))

      assert_nil @client.country_codes(["Q1"]).dig("Q1", "code")
    end

    test "labels reads English labels with wbgetentities and caches them" do
      limiter = mock("limiter")
      limiter.stubs(:acquire!)
      client = Client.new(http: ::Wikimedia::Http.new(limiter: limiter), cache: ActiveSupport::Cache::MemoryStore.new)
      body = {entities: {"Q36180" => {"id" => "Q36180", "labels" => {"en" => {"language" => "en", "value" => "writer"}}}}}.to_json
      stub = stub_request(:get, API).with(query: hash_including(action: "wbgetentities", ids: "Q36180", props: "labels", languages: "en|mul"))
        .to_return(json_response(body))

      assert_equal({"Q36180" => "writer"}, client.labels(["Q36180"]))
      assert_equal({"Q36180" => "writer"}, client.labels(["Q36180"]))
      assert_requested stub, times: 1
    end

    test "labels falls back to the all-languages label when an item has no English one" do
      body = {entities: {"Q1" => {"id" => "Q1", "labels" => {"mul" => {"language" => "mul", "value" => "Victor Hugo"}}}}}.to_json
      stub_request(:get, API).with(query: hash_including(action: "wbgetentities", props: "labels")).to_return(json_response(body))

      assert_equal({"Q1" => "Victor Hugo"}, @client.labels(["Q1"]))
    end

    test "country_codes asks the label service for English, then the all-languages label" do
      stub = stub_request(:post, SPARQL).with { |request| sparql_query(request).include?('wikibase:language "en,mul"') }
        .to_return(json_response({results: {bindings: []}}.to_json))

      @client.country_codes(["Q30"])

      assert_requested stub
    end

    test "a client given no cache uses the external API cache" do
      Rails.application.config.x.stubs(:external_api_cache).returns(ActiveSupport::Cache::MemoryStore.new)
      limiter = mock("limiter")
      limiter.stubs(:acquire!)
      client = Client.new(http: ::Wikimedia::Http.new(limiter: limiter))
      body = {entities: {"Q36180" => {"id" => "Q36180", "labels" => {"en" => {"language" => "en", "value" => "writer"}}}}}.to_json
      stub = stub_request(:get, API).with(query: hash_including(action: "wbgetentities", props: "labels")).to_return(json_response(body))

      2.times { client.labels(["Q36180"]) }

      assert_requested stub, times: 1
    end
  end
end

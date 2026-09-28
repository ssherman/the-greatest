# frozen_string_literal: true

require "test_helper"

module Wikipedia
  class ClientTest < ActiveSupport::TestCase
    API = "https://en.wikipedia.org/w/api.php"

    def setup
      limiter = mock("limiter")
      limiter.stubs(:acquire!)
      @client = Client.new(http: ::Wikimedia::Http.new(limiter: limiter))
    end

    def respond_with(name)
      stub_request(:get, API).with(query: hash_including(action: "query"))
        .to_return(status: 200, body: file_fixture("wikipedia/#{name}").read, headers: {"Content-Type" => "application/json"})
    end

    test "reads the lead, page id, canonical URL and Wikidata item of one exact title" do
      fixture_body = file_fixture("wikipedia/lead_leo_tolstoy.json").read
      stub = stub_request(:get, API)
        .with(query: hash_including(action: "query", prop: "extracts|pageprops|info", inprop: "url", exintro: "1",
          explaintext: "1", redirects: "1", titles: "Leo Tolstoy"))
        .to_return(status: 200, body: fixture_body)

      lead = @client.lead(language: "en", title: "Leo Tolstoy")

      assert_requested stub
      assert_equal "en", lead.language
      assert_equal [18622119, "Leo Tolstoy", "https://en.wikipedia.org/wiki/Leo_Tolstoy", "Q7243"],
        [lead.page_id, lead.title, lead.url, lead.wikibase_item]
      assert_not lead.disambiguation?
      assert lead.extract.start_with?("Count Lev Nikolayevich Tolstoy")
      assert_equal "en:18622119", lead.source_id
      assert_equal fixture_body, lead.raw
    end

    test "flags a disambiguation page" do
      respond_with("lead_john_smith.json")

      assert @client.lead(language: "en", title: "John Smith").disambiguation?
    end

    test "returns nil for a title with no page" do
      body = {batchcomplete: true, query: {pages: [{ns: 0, title: "No Such Page Here", missing: true}]}}.to_json
      stub_request(:get, API).with(query: hash_including(action: "query")).to_return(status: 200, body: body)

      assert_nil @client.lead(language: "en", title: "No Such Page Here")
    end

    test "refuses a malformed language or a blank title without calling out" do
      stub = stub_request(:get, /wikipedia\.org/)

      assert_raises(ArgumentError) { @client.lead(language: "evil.com/x?", title: "Leo Tolstoy") }
      assert_raises(ArgumentError) { @client.lead(language: "en", title: " ") }
      assert_not_requested stub
    end

    test "has no search method" do
      assert_not Client.public_method_defined?(:search)
    end
  end
end

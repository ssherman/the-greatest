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

    test "article returns lead, plot and infobox fields from two requests" do
      query = stub_request(:get, API)
        .with(query: hash_including(action: "query", prop: "extracts|pageprops|info", inprop: "url", explaintext: "1",
          exsectionformat: "wiki", redirects: "1", titles: "Lolita"))
        .to_return(status: 200, body: file_fixture("wikipedia/article_lolita.json").read)
      parse = stub_request(:get, API)
        .with(query: hash_including(action: "parse", page: "Lolita", prop: "wikitext", section: "0", redirects: "1"))
        .to_return(status: 200, body: file_fixture("wikipedia/article_lolita_wikitext.json").read)

      article = @client.article(language: "en", title: "Lolita")

      assert_requested query
      assert_requested parse
      assert_equal [17792, "Lolita", "https://en.wikipedia.org/wiki/Lolita"], [article.page_id, article.title, article.url]
      assert_equal "Lolita is a 1955 novel by Vladimir Nabokov.\nIt is narrated by Humbert Humbert.", article.lead
      assert_equal "Humbert travels to New England.\n\nHe meets Dolores.", article.plot
      assert_equal "United States", article.infobox["country"]
      assert_equal "New England, Ramsdale", article.infobox["set_in"]
    end

    test "article returns nil for a missing page without a parse request" do
      body = {query: {pages: [{ns: 0, title: "Nope", missing: true}]}}.to_json
      stub_request(:get, API).with(query: hash_including(action: "query")).to_return(status: 200, body: body)
      parse = stub_request(:get, API).with(query: hash_including(action: "parse"))

      assert_nil @client.article(language: "en", title: "Nope")
      assert_not_requested parse
    end

    test "article returns nil for a disambiguation page" do
      respond_with("lead_john_smith.json")
      parse = stub_request(:get, API).with(query: hash_including(action: "parse"))

      assert_nil @client.article(language: "en", title: "John Smith")
      assert_not_requested parse
    end

    test "article parses the resolved title after a redirect" do
      body = {query: {pages: [{pageid: 5, title: "Lolita", fullurl: "u", extract: "Lead."}]}}.to_json
      stub_request(:get, API).with(query: hash_including(action: "query", titles: "Lolita (novel)")).to_return(status: 200, body: body)
      parse = stub_request(:get, API).with(query: hash_including(action: "parse", page: "Lolita"))
        .to_return(status: 200, body: {parse: {title: "Lolita", wikitext: ""}}.to_json)

      article = @client.article(language: "en", title: "Lolita (novel)")

      assert_requested parse
      assert_equal "Lead.", article.lead
      assert_nil article.plot
      assert_equal({}, article.infobox)
    end

    test "article truncates lead and plot to their budgets" do
      extract = "#{"a" * 3_000}\n== Synopsis ==\n#{"b" * 7_000}\n== Other ==\nz"
      body = {query: {pages: [{pageid: 5, title: "T", fullurl: "u", extract: extract}]}}.to_json
      stub_request(:get, API).with(query: hash_including(action: "query")).to_return(status: 200, body: body)
      stub_request(:get, API).with(query: hash_including(action: "parse")).to_return(status: 200, body: {parse: {wikitext: ""}}.to_json)

      article = @client.article(language: "en", title: "T")

      assert_equal [2_000, 6_000], [article.lead.length, article.plot.length]
    end

    test "article refuses a malformed language or blank title" do
      assert_raises(ArgumentError) { @client.article(language: "evil.com/x?", title: "X") }
      assert_raises(ArgumentError) { @client.article(language: "en", title: " ") }
    end

    test "has no search method" do
      assert_not Client.public_method_defined?(:search)
    end
  end
end

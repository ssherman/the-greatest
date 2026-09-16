# frozen_string_literal: true

require "test_helper"

module Books
  module OpenLibrary
    class ClientTest < ActiveSupport::TestCase
      BASE_URL = "http://open-library.test:8080"

      def setup
        @config = Books::OpenLibrary::Configuration.new(base_url: BASE_URL)
        @breaker = Books::OpenLibrary::CircuitBreaker.new(
          key: "test:open_library:client",
          failure_threshold: 5,
          cooldown: 60,
          redis: Books::OpenLibrary::FakeRedis.new
        )
        @client = Books::OpenLibrary::Client.new(config: @config, breaker: @breaker)
      end

      # ------------------------------------------------------------- fixtures

      def source_version_hash
        {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
         "pipeline_version" => 1, "matcher_version" => 2}
      end

      def envelope(data)
        {"source_version" => source_version_hash, "data" => data}
      end

      def work_record_hash(key: "OL468431W", redirected_from: [], title: "The Great Gatsby")
        {
          "key" => {"source" => "openlibrary", "key" => key},
          "redirected_from" => redirected_from.map { |k| {"source" => "openlibrary", "key" => k} },
          "title" => title,
          "subtitle" => nil,
          "description" => "...",
          "authors" => [{"key" => {"source" => "openlibrary", "key" => "OL27349A"}, "name" => "F. Scott Fitzgerald"}],
          "subjects" => ["Fiction"],
          "year_evidence" => {
            "declared_year" => 1925, "min_edition_year" => 1925, "second_min_edition_year" => 1926,
            "modal_edition_year" => 2004, "modal_edition_year_count" => 12, "edition_year_count" => 180,
            "edition_count" => 190
          },
          "popularity" => {"edition_count" => 190, "readinglog_count" => 5000, "ratings_count" => 300, "ratings_avg" => 3.9}
        }
      end

      def edition_record_hash(key: "OL1M")
        {
          "key" => {"source" => "openlibrary", "key" => key},
          "title" => "The Great Gatsby", "subtitle" => nil, "publish_year" => 1925,
          "publish_date_raw" => "1925", "language_code" => "eng", "page_count" => 218,
          "publisher" => "Scribner", "physical_format" => "Hardcover", "edition_name" => nil,
          "series" => [], "isbn13" => ["9780743273565"], "isbn10" => [], "oclc" => [], "lccn" => [], "asin" => [],
          "goodreads" => []
        }
      end

      def author_record_hash(key: "OL27349A")
        {
          "key" => {"source" => "openlibrary", "key" => key},
          "redirected_from" => [],
          "name" => "F. Scott Fitzgerald",
          "alternate_names" => ["Francis Scott Fitzgerald"],
          "birth_year" => 1896,
          "death_year" => 1940
        }
      end

      def shelf_entry_hash(key: "OL468431W")
        {
          "key" => {"source" => "openlibrary", "key" => key},
          "title" => "The Great Gatsby",
          "readinglog_count" => 5000,
          "edition_count" => 190,
          "ratings_count" => 300,
          "declared_year" => 1925
        }
      end

      def identifier_hit_hash(work_key: "OL468431W", redirected_from: [], edition_keys: ["OL1M"])
        {
          "work" => {"source" => "openlibrary", "key" => work_key},
          "redirected_from" => redirected_from.map { |k| {"source" => "openlibrary", "key" => k} },
          "editions" => edition_keys.map { |k| {"source" => "openlibrary", "key" => k} },
          "id_type" => "isbn13",
          "value" => "9780743273565"
        }
      end

      def resolve_response_body(decision_verdict: "accept", decision_key: "OL468431W", second_verdict: "reject", second_record: nil)
        {
          "source_version" => source_version_hash,
          "data" => {
            "decision" => {
              "verdict" => decision_verdict,
              "key" => decision_key ? {"source" => "openlibrary", "key" => decision_key} : nil,
              "score" => (decision_verdict == "abstain") ? nil : 0.98,
              "margin" => 0.4,
              "reason" => "identifier match"
            },
            "guards_tripped" => [],
            "volume_guards_tripped" => [],
            "candidates" => [
              {
                "key" => {"source" => "openlibrary", "key" => "OL468431W"},
                "score" => 0.98,
                "rules" => ["identifier", "author_title_fp"],
                "margin" => 0.4,
                "verdict" => (decision_verdict == "accept") ? "accept" : "abstain",
                "evidence" => {"title_similarity" => {"value" => 1.0, "weight" => 1.0}},
                "conflicts" => [],
                "diff" => [
                  {"field" => "title", "ours" => "The Great Gatsby", "theirs" => "The Great Gatsby", "kind" => "agreement"},
                  {"field" => "description", "ours" => nil, "theirs" => "...", "kind" => "fill"}
                ],
                "record" => work_record_hash
              },
              {
                "key" => {"source" => "openlibrary", "key" => "OL999W"},
                "score" => 0.42,
                "rules" => ["author_title_fp"],
                "margin" => 0.56,
                "verdict" => second_verdict,
                "evidence" => {},
                "conflicts" => [],
                "diff" => [],
                "record" => second_record
              }
            ]
          }
        }
      end

      # ------------------------------------------------------------------ #work

      test "#work returns a Work built from the enveloped record" do
        stub_request(:get, "#{BASE_URL}/works/OL468431W").to_return(status: 200, body: envelope(work_record_hash).to_json)

        work = @client.work("OL468431W")

        assert_instance_of Books::OpenLibrary::Work, work
        assert_equal "OL468431W", work.key
        assert_equal "openlibrary", work.source
        assert_equal "The Great Gatsby", work.title
        assert_nil work.subtitle
        assert_equal ["OL27349A"], work.author_keys
        assert_equal ["F. Scott Fitzgerald"], work.author_names
        assert_equal ["Fiction"], work.subjects
        assert_equal 1925, work.year_evidence[:declared_year]
        assert_equal 5000, work.popularity[:readinglog_count]
        assert_empty work.redirected_from
        assert_equal 1, work.source_version[:normalizer_version]
      end

      test "#work on a redirected key exposes redirected_from as bare key strings" do
        stub_request(:get, "#{BASE_URL}/works/OL1W").to_return(
          status: 200, body: envelope(work_record_hash(key: "OL468431W", redirected_from: ["OL1W"])).to_json
        )

        work = @client.work("OL1W")

        assert_equal ["OL1W"], work.redirected_from
        assert_equal "OL468431W", work.key
      end

      # -------------------------------------------------------------- #editions

      test "#editions returns an Array of Edition" do
        stub_request(:get, "#{BASE_URL}/works/OL468431W/editions")
          .to_return(status: 200, body: envelope([edition_record_hash]).to_json)

        editions = @client.editions("OL468431W")

        assert_equal 1, editions.size
        edition = editions.first
        assert_instance_of Books::OpenLibrary::Edition, edition
        assert_equal "OL1M", edition.key
        assert_equal "openlibrary", edition.source
        assert_equal ["9780743273565"], edition.isbn13
        assert_equal 1925, edition.publish_year
      end

      # --------------------------------------------------------------- #author

      test "#author returns an Author built from the enveloped record" do
        stub_request(:get, "#{BASE_URL}/authors/OL27349A").to_return(status: 200, body: envelope(author_record_hash).to_json)

        author = @client.author("OL27349A")

        assert_instance_of Books::OpenLibrary::Author, author
        assert_equal "OL27349A", author.key
        assert_equal "openlibrary", author.source
        assert_equal "F. Scott Fitzgerald", author.name
        assert_equal ["Francis Scott Fitzgerald"], author.alternate_names
        assert_equal 1896, author.birth_year
        assert_equal 1940, author.death_year
      end

      # --------------------------------------------------------- #author_works

      test "#author_works passes limit and offset as query params and returns ShelfEntry objects" do
        stub_request(:get, "#{BASE_URL}/authors/OL27349A/works")
          .with(query: {"limit" => "10", "offset" => "20"})
          .to_return(status: 200, body: envelope([shelf_entry_hash]).to_json)

        shelf = @client.author_works("OL27349A", limit: 10, offset: 20)

        assert_equal 1, shelf.size
        entry = shelf.first
        assert_instance_of Books::OpenLibrary::ShelfEntry, entry
        assert_equal "OL468431W", entry.key
        assert_equal 5000, entry.readinglog_count
      end

      test "#author_works defaults limit to 50 and offset to 0" do
        stub_request(:get, "#{BASE_URL}/authors/OL27349A/works")
          .with(query: {"limit" => "50", "offset" => "0"})
          .to_return(status: 200, body: envelope([]).to_json)

        assert_empty @client.author_works("OL27349A")
      end

      # ------------------------------------------------------------ #identifier

      test "#identifier returns an Array even for one hit" do
        stub_request(:get, "#{BASE_URL}/identifiers/isbn13/9780743273565")
          .to_return(status: 200, body: envelope([identifier_hit_hash]).to_json)

        hits = @client.identifier("isbn13", "9780743273565")

        assert_instance_of Array, hits
        assert_equal 1, hits.size
        hit = hits.first
        assert_instance_of Books::OpenLibrary::IdentifierHit, hit
        assert_equal "OL468431W", hit.work_key
        assert_equal "openlibrary", hit.source
        assert_equal ["OL1M"], hit.edition_keys
        assert_empty hit.redirected_from
        assert_equal "isbn13", hit.id_type
        assert_equal "9780743273565", hit.value
      end

      test "#identifier with an unsupported type raises ArgumentError before any request" do
        assert_raises(ArgumentError) { @client.identifier("issn", "1234-5678") }

        assert_not_requested :get, "#{BASE_URL}/identifiers/issn/1234-5678"
      end

      # ----------------------------------------------------------- #works_batch

      test "#works_batch returns a Hash keyed by requested key, mapping a null value to nil" do
        stub_request(:post, "#{BASE_URL}/works/batch")
          .with(body: {keys: ["OL468431W", "OL999W"]}.to_json)
          .to_return(status: 200, body: envelope({"OL468431W" => work_record_hash, "OL999W" => nil}).to_json)

        result = @client.works_batch(["OL468431W", "OL999W"])

        assert_instance_of Books::OpenLibrary::Work, result["OL468431W"]
        assert_nil result["OL999W"]
      end

      test "#works_batch with 501 keys raises ArgumentError before making a request" do
        keys = Array.new(501) { |i| "OL#{i}W" }

        assert_raises(ArgumentError) { @client.works_batch(keys) }

        assert_not_requested :post, "#{BASE_URL}/works/batch"
      end

      # --------------------------------------------------------- #authors_batch

      test "#authors_batch returns a Hash keyed by requested key, mapping a null value to nil" do
        stub_request(:post, "#{BASE_URL}/authors/batch")
          .with(body: {keys: ["OL27349A", "OL0A"]}.to_json)
          .to_return(status: 200, body: envelope({"OL27349A" => author_record_hash, "OL0A" => nil}).to_json)

        result = @client.authors_batch(["OL27349A", "OL0A"])

        assert_instance_of Books::OpenLibrary::Author, result["OL27349A"]
        assert_nil result["OL0A"]
      end

      test "#authors_batch with 501 keys raises ArgumentError before making a request" do
        keys = Array.new(501) { |i| "OL#{i}A" }

        assert_raises(ArgumentError) { @client.authors_batch(keys) }

        assert_not_requested :post, "#{BASE_URL}/authors/batch"
      end

      # -------------------------------------------------------------- #resolve

      test "#resolve sends exactly the given allow-listed fields, omitting empty optionals" do
        stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: resolve_response_body.to_json)

        @client.resolve(title: "The Great Gatsby", author_names: ["F. Scott Fitzgerald"], year: 1925, isbn13: ["9780743273565"])

        assert_requested(:post, "#{BASE_URL}/resolve") do |req|
          JSON.parse(req.body) == {
            "title" => "The Great Gatsby",
            "author_names" => ["F. Scott Fitzgerald"],
            "year" => 1925,
            "isbn13" => ["9780743273565"]
          }
        end
      end

      test "#resolve includes every allow-listed optional field when given, and nothing else" do
        stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: resolve_response_body.to_json)

        @client.resolve(
          title: "The Great Gatsby",
          subtitle: "A Novel",
          author_names: ["F. Scott Fitzgerald"],
          year: 1925,
          isbn13: ["9780743273565"],
          isbn10: ["0743273567"],
          asin: ["B000FC1PJI"],
          goodreads_id: ["4671"],
          existing_ol_key: "OL468431W",
          description: "A novel set in the Jazz Age",
          subjects: ["Fiction"],
          limit: 5
        )

        assert_requested(:post, "#{BASE_URL}/resolve") do |req|
          JSON.parse(req.body) == {
            "title" => "The Great Gatsby",
            "subtitle" => "A Novel",
            "author_names" => ["F. Scott Fitzgerald"],
            "year" => 1925,
            "isbn13" => ["9780743273565"],
            "isbn10" => ["0743273567"],
            "asin" => ["B000FC1PJI"],
            "goodreads_id" => ["4671"],
            "existing_ol_key" => "OL468431W",
            "description" => "A novel set in the Jazz Age",
            "subjects" => ["Fiction"],
            "limit" => 5
          }
        end
      end

      test "#resolve with only an identifier sends title as an empty string" do
        stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: resolve_response_body.to_json)

        @client.resolve(title: nil, isbn13: ["9780743273565"])

        assert_requested(:post, "#{BASE_URL}/resolve") do |req|
          JSON.parse(req.body) == {"title" => "", "isbn13" => ["9780743273565"]}
        end
      end

      test "#resolve sends the request with config.resolve_timeout" do
        @client.base_client.expects(:post)
          .with("/resolve", anything, timeout: @config.resolve_timeout)
          .returns({success: true, data: resolve_response_body, errors: [], metadata: {}})

        @client.resolve(title: "The Great Gatsby")
      end

      test "#resolve returns a Resolution whose candidates are in the served order, never re-sorted" do
        stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: resolve_response_body.to_json)

        resolution = @client.resolve(title: "The Great Gatsby", author_names: ["F. Scott Fitzgerald"], year: 1925)

        assert_instance_of Books::OpenLibrary::Resolution, resolution
        assert_equal ["OL468431W", "OL999W"], resolution.candidates.map(&:work_key)
        scores = resolution.candidates.map(&:score)
        assert_operator scores.first, :>=, scores.last
      end

      test "#resolve exposes decision.reason and resolves #accepted to the matching candidate on accept" do
        stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: resolve_response_body.to_json)

        resolution = @client.resolve(title: "The Great Gatsby")

        assert resolution.accept?
        assert_equal "identifier match", resolution.decision.reason
        assert_equal "OL468431W", resolution.decision.key
        assert_equal resolution.candidates.first, resolution.accepted
      end

      test "#resolve exposes a nil Candidate#record when the service sends record: null" do
        stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: resolve_response_body.to_json)

        resolution = @client.resolve(title: "The Great Gatsby")

        assert_nil resolution.candidates.last.record
      end

      test "#resolve on an abstain decision exposes a nil decision.key and a nil #accepted" do
        stub_request(:post, "#{BASE_URL}/resolve").to_return(
          status: 200,
          body: resolve_response_body(decision_verdict: "abstain", decision_key: nil, second_verdict: "abstain").to_json
        )

        resolution = @client.resolve(title: "The Great Gatsby")

        assert resolution.abstain?
        assert_not resolution.accept?
        assert_nil resolution.decision.key
        assert_nil resolution.accepted
      end

      # --------------------------------------------------------------- #version

      test "#version returns a plain symbol-keyed Hash" do
        stub_request(:get, "#{BASE_URL}/version")
          .to_return(status: 200, body: {"artifact" => "2026-07-31", "pipeline_version" => 1}.to_json)

        version = @client.version

        assert_instance_of Hash, version
        assert_equal "2026-07-31", version[:artifact]
        assert_equal 1, version[:pipeline_version]
      end
    end
  end
end

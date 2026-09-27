# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      class OpenLibrarySourceTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"

        def setup
          @client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:author_source:open_library", failure_threshold: 5, cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          @tolstoy = books_authors(:tolstoy)
        end

        def source(key)
          OpenLibrarySource.new(query: ImportQuery.new(name: "Leo Tolstoy", open_library_author_key: key), client: @client)
        end

        def stub_author(key, record_key: key, redirected_from: [], name: "Leo Tolstoy", status: 200)
          body = {
            "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1, "pipeline_version" => 1, "matcher_version" => 2},
            "data" => {
              "key" => {"source" => "openlibrary", "key" => record_key},
              "redirected_from" => redirected_from.map { |k| {"source" => "openlibrary", "key" => k} },
              "name" => name, "alternate_names" => ["Lev Nikolayevich Tolstoy"], "birth_year" => 1828, "death_year" => 1910
            }
          }
          stub_request(:get, "#{BASE_URL}/authors/#{key}").to_return(status: status, body: (status == 200) ? body.to_json : "{}")
        end

        test "a query without a key contributes nothing and makes no request" do
          assert_equal [], OpenLibrarySource.new(query: ImportQuery.new(name: "Leo Tolstoy"), client: @client).call
          assert_not_requested(:get, %r{#{BASE_URL}/authors/}o)
        end

        test "an unheld key is one external-only accepted candidate carrying the Open Library record" do
          stub_author("OL26783A")

          candidates = source("OL26783A").call

          assert_equal 1, candidates.size
          candidate = candidates.first
          assert_nil candidate.record
          assert_equal ["OL26783A", :open_library, [:open_library]], [candidate.external_key, candidate.external_source, candidate.sources]
          assert candidate.external_accepted?
          assert_instance_of ::Books::OpenLibrary::Author, candidate.external_record
          assert_equal ["Leo Tolstoy", 1828, 1910, ["Lev Nikolayevich Tolstoy"]],
            candidate.evidence.values_at(:title, :birth_year, :death_year, :alternate_names)
        end

        test "a local author holding the key, or a key it redirects from, is a holder candidate with external_ evidence" do
          @tolstoy.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL1A")
          stub_author("OL2A", record_key: "OL2A", redirected_from: ["OL1A"])

          candidates = source("OL2A").call

          assert_equal [@tolstoy], candidates.map(&:record)
          assert_equal "OL2A", candidates.first.external_key
          assert_nil candidates.first.evidence[:title]
          assert_equal ["Leo Tolstoy", 1828], candidates.first.evidence.values_at(:external_title, :external_birth_year)
        end

        test "a 404 is no candidates, not a failure" do
          stub_author("OL404A", status: 404)

          assert_equal [], source("OL404A").call
        end

        test "a server error propagates so the finder records a failed source" do
          stub_author("OL500A", status: 500)

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { source("OL500A").call }
        end
      end
    end
  end
end

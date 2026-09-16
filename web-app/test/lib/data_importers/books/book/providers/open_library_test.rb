# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      module Providers
        class OpenLibraryTest < ActiveSupport::TestCase
          BASE_URL = "http://open-library.test:8080"

          def setup
            @client = ::Books::OpenLibrary::Client.new(
              config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
              breaker: ::Books::OpenLibrary::CircuitBreaker.new(
                key: "test:providers:open_library",
                failure_threshold: 5,
                cooldown: 60,
                redis: ::Books::OpenLibrary::FakeRedis.new
              )
            )
            @provider = Providers::OpenLibrary.new(client: @client)
          end

          # ----------------------------------------------------------- fixtures

          def source_version_hash
            {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
             "pipeline_version" => 1, "matcher_version" => 2}
          end

          def diff_entry(field:, ours:, theirs:, kind:)
            {"field" => field.to_s, "ours" => ours, "theirs" => theirs, "kind" => kind}
          end

          def candidate_hash(key:, diff:, verdict: "accept")
            {
              "key" => {"source" => "openlibrary", "key" => key},
              "score" => 0.9,
              "rules" => ["identifier"],
              "margin" => 0.4,
              "verdict" => verdict,
              "evidence" => {},
              "conflicts" => [],
              "diff" => diff,
              "record" => nil
            }
          end

          def resolve_response(verdict:, key: "OL468431W", reason: "identifier match", diff: [])
            {
              "source_version" => source_version_hash,
              "data" => {
                "decision" => {
                  "verdict" => verdict,
                  "key" => (verdict == "accept") ? {"source" => "openlibrary", "key" => key} : nil,
                  "score" => (verdict == "abstain") ? nil : 0.9,
                  "margin" => 0.4,
                  "reason" => reason
                },
                "guards_tripped" => [],
                "volume_guards_tripped" => [],
                "candidates" => (verdict == "accept") ? [candidate_hash(key: key, diff: diff)] : []
              }
            }
          end

          def stub_resolve(body)
            stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: body.to_json)
          end

          # -------------------------------------------------------------- accept

          test "accept verdict fills empty fields and reports them in data_populated" do
            book = ::Books::Book.new(title: "The Great Gatsby")
            stub_resolve(resolve_response(verdict: "accept", diff: [
              diff_entry(field: "first_published_year", ours: nil, theirs: 1925, kind: "fill"),
              diff_entry(field: "description", ours: nil, theirs: "A story of the Jazz Age", kind: "fill")
            ]))

            result = @provider.populate(book, query: nil)

            assert result.success?
            assert_equal 1925, book.first_published_year
            assert_equal "A story of the Jazz Age", book.description
            assert_equal "The Great Gatsby", book.title
            assert_includes result.data_populated, "first_published_year"
            assert_includes result.data_populated, "description"
          end

          # ------------------------------------------------------- conflict/enrichment

          test "a conflict on a populated field is left alone and reported as skipped" do
            book = ::Books::Book.new(title: "War and Peace", first_published_year: 1926)
            stub_resolve(resolve_response(verdict: "accept", diff: [
              diff_entry(field: "first_published_year", ours: 1926, theirs: 1925, kind: "conflict")
            ]))

            result = @provider.populate(book, query: nil)

            assert result.success?
            assert_equal 1926, book.first_published_year
            assert_includes result.data_populated, "skipped:first_published_year"
          end

          test "an enrichment on a populated field is left alone and reported as skipped" do
            book = ::Books::Book.new(title: "War and Peace", description: "Our own description")
            stub_resolve(resolve_response(verdict: "accept", diff: [
              diff_entry(field: "description", ours: "Our own description", theirs: "Their longer description", kind: "enrichment")
            ]))

            result = @provider.populate(book, query: nil)

            assert result.success?
            assert_equal "Our own description", book.description
            assert_includes result.data_populated, "skipped:description"
          end

          # ---------------------------------------------------------- abstain/reject

          test "abstain verdict populates nothing and returns a failure naming the reason" do
            book = ::Books::Book.new(title: "The Great Gatsby")
            stub_resolve(resolve_response(verdict: "abstain", reason: "margin too small"))

            result = @provider.populate(book, query: nil)

            refute result.success?
            assert_nil book.first_published_year
            assert_nil book.description
            assert_includes result.errors.join, "margin too small"
          end

          test "reject verdict populates nothing and returns a failure" do
            book = ::Books::Book.new(title: "The Great Gatsby")
            stub_resolve(resolve_response(verdict: "reject", reason: "no plausible candidate"))

            result = @provider.populate(book, query: nil)

            refute result.success?
            assert_nil book.first_published_year
            assert_nil book.description
            assert_includes result.errors.join, "no plausible candidate"
          end

          # -------------------------------------------------------------- identifier

          test "the accepted work key is written via find_or_initialize_by, never build" do
            book = books_books(:war_and_peace)
            stub_resolve(resolve_response(verdict: "accept", key: "OL262758W", diff: []))

            2.times do
              result = @provider.populate(book, query: nil)
              assert result.success?
              book.save!
            end

            identifiers = book.identifiers.where(identifier_type: :books_work_openlibrary_id)
            assert_equal 1, identifiers.count
            assert_equal "OL262758W", identifiers.first.value
          end

          # -------------------------------------------------------- error handling

          test "a CircuitOpenError is caught and converted to a failure result" do
            fake_redis = ::Books::OpenLibrary::FakeRedis.new
            breaker = ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:providers:open_library:open",
              failure_threshold: 5,
              cooldown: 60,
              redis: fake_redis
            )
            # Pre-open the breaker directly rather than burning five failing
            # requests -- exercises the same open? branch with less setup.
            fake_redis.hset("circuit:test:providers:open_library:open", "opened_at", Time.current.to_f.to_s)
            client = ::Books::OpenLibrary::Client.new(
              config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
              breaker: breaker
            )
            provider = Providers::OpenLibrary.new(client: client)
            book = ::Books::Book.new(title: "The Great Gatsby")

            result = provider.populate(book, query: nil)

            refute result.success?
            assert_includes result.errors.join, "CircuitOpenError"
            assert_not_requested :post, "#{BASE_URL}/resolve"
          end

          test "a TimeoutError is caught and converted to a failure result" do
            # WebMock's own .to_timeout maps to Faraday::ConnectionFailed on
            # this adapter (see base_client_test.rb) -- raise
            # Faraday::TimeoutError directly to exercise this mapping.
            stub_request(:post, "#{BASE_URL}/resolve").to_raise(Faraday::TimeoutError)
            book = ::Books::Book.new(title: "The Great Gatsby")

            result = @provider.populate(book, query: nil)

            refute result.success?
            assert_includes result.errors.join, "TimeoutError"
          end

          # ------------------------------------------------------------- one call

          test "makes exactly one HTTP request per populate, and never a follow-up GET" do
            book = ::Books::Book.new(title: "The Great Gatsby")
            stub_resolve(resolve_response(verdict: "accept", diff: []))

            @provider.populate(book, query: nil)

            assert_requested :post, "#{BASE_URL}/resolve", times: 1
            assert_not_requested :get, /works\//
          end

          # --------------------------------------------------- request built from book

          test "builds the resolve request from the book's own state, not the query" do
            book = books_books(:war_and_peace)
            stub_resolve(resolve_response(verdict: "accept", diff: []))

            @provider.populate(book, query: nil)

            assert_requested(:post, "#{BASE_URL}/resolve") do |req|
              body = JSON.parse(req.body)
              body["title"] == "War and Peace" &&
                body["author_names"] == ["Leo Tolstoy"] &&
                body["isbn13"] == ["9780140447934"]
            end
          end

          # ------------------------------------------------------ authors/subjects

          test "authors and subjects diff entries are never applied or reported" do
            book = ::Books::Book.new(title: "The Great Gatsby")
            stub_resolve(resolve_response(verdict: "accept", diff: [
              diff_entry(field: "authors", ours: [], theirs: ["F. Scott Fitzgerald"], kind: "fill"),
              diff_entry(field: "subjects", ours: [], theirs: ["Fiction"], kind: "fill")
            ]))

            result = @provider.populate(book, query: nil)

            assert result.success?
            assert_empty result.data_populated
            assert_empty book.authors
          end
        end
      end
    end
  end
end

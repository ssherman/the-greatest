# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class OpenLibrarySourceTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"

        def setup
          @client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:sources:open_library", failure_threshold: 5, cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          @held_key = identifiers(:crime_and_punishment_openlibrary).value # "OL262758W", held by crime_and_punishment
        end

        def source(query, limit: 5)
          OpenLibrarySource.new(query: query, client: @client, limit: limit)
        end

        def query(**attributes)
          ImportQuery.new(title: "Crime and Punishment", author_names: ["Fyodor Dostoevsky"], **attributes)
        end

        def work_record(key:, title:, authors: ["Fyodor Dostoevsky"], declared_year: 1866, redirected_from: [])
          {
            "key" => {"source" => "openlibrary", "key" => key},
            "title" => title,
            "subtitle" => nil,
            "description" => nil,
            "authors" => authors.each_with_index.map { |name, i| {"key" => {"source" => "openlibrary", "key" => "OL#{i}A"}, "name" => name} },
            "subjects" => [],
            "year_evidence" => {"declared_year" => declared_year, "min_edition_year" => 1917},
            "popularity" => nil,
            "redirected_from" => redirected_from.map { |k| {"source" => "openlibrary", "key" => k} }
          }
        end

        def candidate_hash(key:, verdict:, score:, record:, rules: ["title_author"], margin: 0.2)
          {"key" => {"source" => "openlibrary", "key" => key}, "score" => score, "rules" => rules, "margin" => margin,
           "verdict" => verdict, "evidence" => {}, "conflicts" => [], "diff" => [], "record" => record}
        end

        def resolve_response(verdict:, key: nil, candidates: [], reason: "test")
          {
            "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1, "pipeline_version" => 1, "matcher_version" => 2},
            "data" => {
              "decision" => {"verdict" => verdict, "key" => key && {"source" => "openlibrary", "key" => key}, "score" => 0.9, "margin" => 0.3, "reason" => reason},
              "guards_tripped" => [], "volume_guards_tripped" => [], "candidates" => candidates
            }
          }
        end

        def stub_resolve(body, &request_check)
          stub = stub_request(:post, "#{BASE_URL}/resolve")
          stub = stub.with(&request_check) if request_check
          stub.to_return(status: 200, body: body.to_json)
        end

        test "name is :open_library" do
          assert_equal :open_library, source(query).name
        end

        test "sends the query's fields, the work key as existing_ol_key and the limit" do
          stub_resolve(resolve_response(verdict: "abstain")) do |request|
            body = JSON.parse(request.body)
            body == {"title" => "Crime and Punishment", "author_names" => ["Fyodor Dostoevsky"], "year" => 1866,
                     "isbn13" => ["9780140449136"], "existing_ol_key" => "OL262758W", "limit" => 5}
          end

          candidates = source(query(year: 1866, isbn13: ["9780140449136"], open_library_work_key: "OL262758W")).call

          assert_equal [], candidates
        end

        test "limit is passed through to the service" do
          stub_resolve(resolve_response(verdict: "abstain")) { |request| JSON.parse(request.body)["limit"] == 2 }

          assert_equal [], source(query, limit: 2).call
          assert_requested(:post, "#{BASE_URL}/resolve")
        end

        test "a blank title is sent as an empty string for an identifier-only query" do
          stub_resolve(resolve_response(verdict: "abstain")) { |request| JSON.parse(request.body)["title"] == "" }

          source(ImportQuery.new(title: nil, isbn13: ["9780140449136"])).call

          assert_requested(:post, "#{BASE_URL}/resolve")
        end

        test "a work nobody holds locally is one external-only candidate with the work's title, authors and year as evidence" do
          record = work_record(key: "OL999W", title: "Crime & Punishment", declared_year: nil)
          stub_resolve(resolve_response(verdict: "abstain", candidates: [candidate_hash(key: "OL999W", verdict: "abstain", score: 0.55, record: record)]))

          candidates = source(query).call

          assert_equal 1, candidates.size
          candidate = candidates.first
          assert_not candidate.local?
          assert_equal ["OL999W", :open_library, [:open_library], {open_library: 0.55}],
            [candidate.external_key, candidate.external_source, candidate.sources, candidate.scores]
          assert_equal "Crime & Punishment", candidate.evidence[:title]
          assert_equal ["Fyodor Dostoevsky"], candidate.evidence[:creators]
          assert_equal 1917, candidate.evidence[:year], "falls back to min_edition_year when declared_year is absent"
          assert_equal ["abstain", 0.55, 0.2, ["title_author"]],
            candidate.evidence.values_at(:external_verdict, :external_score, :external_margin, :external_rules)
          assert_instance_of ::Books::OpenLibrary::Candidate, candidate.external_record
        end

        test "a work a local book holds becomes one candidate carrying both halves, with the external facts under external_ keys" do
          record = work_record(key: @held_key, title: "Crime and Punishment")
          stub_resolve(resolve_response(verdict: "accept", key: @held_key, candidates: [candidate_hash(key: @held_key, verdict: "accept", score: 0.93, record: record)]))

          candidates = source(query).call

          assert_equal 1, candidates.size
          candidate = candidates.first
          assert_equal books_books(:crime_and_punishment), candidate.record
          assert_equal @held_key, candidate.external_key
          assert candidate.external_accepted?
          assert_equal "Crime and Punishment", candidate.evidence[:external_title]
          assert_equal 1866, candidate.evidence[:external_year]
          assert_nil candidate.evidence[:title], "the finder fills title from the local record"
        end

        test "two local books holding the same key are two candidates, in id order" do
          other = books_books(:war_and_peace)
          other.identifiers.create!(identifier_type: :books_work_openlibrary_id, value: @held_key)
          record = work_record(key: @held_key, title: "Crime and Punishment")
          stub_resolve(resolve_response(verdict: "accept", key: @held_key, candidates: [candidate_hash(key: @held_key, verdict: "accept", score: 0.93, record: record)]))

          candidates = source(query).call

          assert_equal [books_books(:crime_and_punishment), other].sort_by(&:id), candidates.map(&:record)
          assert_equal [@held_key, @held_key], candidates.map(&:external_key)
        end

        test "a local book holding a key the work redirects from is a holder of the work" do
          record = work_record(key: "OL1000W", title: "Crime and Punishment", redirected_from: [@held_key])
          stub_resolve(resolve_response(verdict: "abstain", candidates: [candidate_hash(key: "OL1000W", verdict: "abstain", score: 0.6, record: record)]))

          candidates = source(query).call

          assert_equal [books_books(:crime_and_punishment)], candidates.map(&:record)
          assert_equal ["OL1000W"], candidates.map(&:external_key)
        end

        test "a book holding both the work's key and a key it redirects from is one holder, not two" do
          books_books(:crime_and_punishment).identifiers.create!(identifier_type: :books_work_openlibrary_id, value: "OL1000W")
          record = work_record(key: "OL1000W", title: "Crime and Punishment", redirected_from: [@held_key])
          stub_resolve(resolve_response(verdict: "abstain", candidates: [candidate_hash(key: "OL1000W", verdict: "abstain", score: 0.6, record: record)]))

          candidates = source(query).call

          assert_equal [books_books(:crime_and_punishment)], candidates.map(&:record)
        end

        test "keeps the whole resolution for the provider" do
          stub_resolve(resolve_response(verdict: "reject", reason: "no candidate"))
          s = source(query)

          assert_nil s.resolution
          s.call

          assert s.resolution.reject?
          assert_equal "no candidate", s.resolution.decision.reason
        end

        test "returns at most the candidates the service returned, in the service's order" do
          records = [["OL1W", 0.9], ["OL2W", 0.7]].map { |key, score| candidate_hash(key: key, verdict: "abstain", score: score, record: work_record(key: key, title: "Crime and Punishment")) }
          stub_resolve(resolve_response(verdict: "abstain", candidates: records))

          assert_equal %w[OL1W OL2W], source(query).call.map(&:external_key)
        end

        test "a service error propagates so the finder records the source as failed" do
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 500, body: "boom")

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { source(query).call }
        end
      end
    end
  end
end

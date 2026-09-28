# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Author
      class ImporterTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"

        def setup
          ::Search::Books::Search::AuthorByName.stubs(:call).returns([])
          # Sidekiq runs inline in tests; a real enqueue would run the whole
          # Wikidata step. Tests that care about the enqueue set their own
          # expectation, which takes precedence over this stub.
          ::Books::Authors::WikidataJob.stubs(:perform_async)
          client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:author_importer:open_library", failure_threshold: 5, cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          ::Books::OpenLibrary::Client.stubs(:new).returns(client)
        end

        def stub_author(key, name: "Anna Brenner", status: 200)
          body = {"source_version" => nil, "data" => {"key" => {"source" => "openlibrary", "key" => key}, "redirected_from" => [],
                                                      "name" => name, "alternate_names" => ["A. Brenner"], "birth_year" => 1901, "death_year" => 1970}}
          stub_request(:get, "#{BASE_URL}/authors/#{key}").to_return(status: status, body: (status == 200) ? body.to_json : "{}")
        end

        test "an exact name match returns the existing author without running a provider" do
          Providers::OpenLibrary.any_instance.expects(:populate).never

          result = Importer.call(name: "Leo Tolstoy")

          assert_equal books_authors(:tolstoy), result.item
          assert_not result.created?
          assert result.match.matched?
        end

        test "a name-only import creates and persists the author with no Open Library request" do
          result = Importer.call(name: "Anna Brenner", work_titles: ["The Quiet Year"])

          assert result.item.persisted?
          assert result.created?
          assert_equal "Anna Brenner", result.item.name
          assert_equal result.item, result.match.decision.reload.record
          assert_not_requested(:get, %r{#{BASE_URL}/authors/}o)
        end

        test "a keyed import makes one Open Library request: the provider reuses the finder's record" do
          stub_author("OL77A")

          result = Importer.call(name: "Anna Brenner", open_library_author_key: "OL77A")

          author = result.item.reload
          assert_equal [1901, 1970, ["A. Brenner"]], [author.birth_year, author.death_year, author.alternate_names]
          assert author.identifiers.exists?(identifier_type: :books_author_openlibrary_id, value: "OL77A")
          assert_requested(:get, "#{BASE_URL}/authors/OL77A", times: 1)
        end

        test "a key-only import takes the name from Open Library" do
          stub_author("OL77A")

          result = Importer.call(open_library_author_key: "OL77A")

          assert result.item.persisted?
          assert_equal "Anna Brenner", result.item.name
        end

        test "an Open Library outage still creates the author from the name" do
          stub_author("OL77A", status: 500)

          result = Importer.call(name: "Anna Brenner", open_library_author_key: "OL77A")

          assert result.item.persisted?
          assert result.created?
          # Enrichment still queues and succeeds, so the import overall
          # succeeds; the outage shows up as OpenLibrary's own failure.
          assert result.success?
          assert_equal ["DataImporters::Books::Author::Providers::OpenLibrary"], result.failed_providers.map(&:provider_name)
        end

        test "re-importing by name or by key is idempotent" do
          stub_author("OL77A")
          first = Importer.call(name: "Anna Brenner", open_library_author_key: "OL77A").item

          by_name = Importer.call(name: "Anna Brenner")
          by_key = Importer.call(open_library_author_key: "OL77A")

          assert_equal [first, first], [by_name.item, by_key.item]
          assert_equal 1, ::Books::Author.where(name: "Anna Brenner").count
        end

        test "when the AI rejects the author holding the key, the new author is created without it and the pair is flagged" do
          holder = books_authors(:king)
          holder.identifiers.create!(identifier_type: :books_author_openlibrary_id, value: "OL77A")
          stub_author("OL77A")
          task = stub("select_candidate_task")
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.stubs(:new).returns(task)
          task.stubs(:call).returns(::Services::Ai::Result.new(success: true, ai_chat: ai_chats(:general_chat),
            data: {selected_index: 0, confidence: "medium", reasoning: "Stephen King is not Anna Brenner.", same_entity_groups: []}))

          result = Importer.call(name: "Anna Brenner", open_library_author_key: "OL77A")

          author = result.item
          assert author.persisted?
          assert result.created?
          assert_equal [holder.id], ::Identifier.where(identifier_type: :books_author_openlibrary_id, value: "OL77A").pluck(:identifiable_id)
          assert ::DuplicateCandidate.raised_by_external_key_collision.exists?(
            item_type: "Books::Author", item_a_id: [author.id, holder.id].min, item_b_id: [author.id, holder.id].max
          )
        end

        test "the query's alternate names seed a new author, without its own name" do
          result = Importer.call(name: "Anna Brenner", alternate_names: ["Anna Brenner", "Anya Brenner"])

          assert_equal ["Anya Brenner"], result.item.alternate_names
        end

        test "a new author gets the Wikidata step queued; a matched author does not" do
          # Replace setup's catch-all stub: a plain `stubs` alongside this
          # `expects(:once)` would silently absorb a second, illegitimate
          # call instead of failing the test.
          ::Books::Authors::WikidataJob.unstub(:perform_async)
          ::Books::Authors::WikidataJob.expects(:perform_async).once

          created = Importer.call(name: "A Brand New Author Name")
          matched = Importer.call(name: created.item.name)

          assert created.created?
          assert_not matched.created?
        end
      end
    end
  end
end

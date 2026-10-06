# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class ImporterTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"

        def setup
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([])
          ::Search::Books::Search::AuthorByName.stubs(:call).returns([])
          # Sidekiq runs inline in tests; a real enqueue would run the AI task.
          ::Books::EnrichBookJob.stubs(:perform_async)
          # ...and a real author import would enqueue the Wikidata step.
          ::Books::Authors::WikidataJob.stubs(:perform_async)
        end

        def stub_open_library_client
          client = ::Books::OpenLibrary::Client.new(
            config: ::Books::OpenLibrary::Configuration.new(base_url: BASE_URL),
            breaker: ::Books::OpenLibrary::CircuitBreaker.new(
              key: "test:importer:open_library",
              failure_threshold: 5,
              cooldown: 60,
              redis: ::Books::OpenLibrary::FakeRedis.new
            )
          )
          ::Books::OpenLibrary::Client.stubs(:new).returns(client)
        end

        def accept_response(diff:, record: nil)
          {
            "source_version" => {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
                                 "pipeline_version" => 1, "matcher_version" => 2},
            "data" => {
              "decision" => {
                "verdict" => "accept",
                "key" => {"source" => "openlibrary", "key" => "OL468431W"},
                "score" => 0.9,
                "margin" => 0.4,
                "reason" => "identifier match"
              },
              "guards_tripped" => [],
              "volume_guards_tripped" => [],
              "candidates" => [
                {
                  "key" => {"source" => "openlibrary", "key" => "OL468431W"},
                  "score" => 0.9,
                  "rules" => ["identifier"],
                  "margin" => 0.4,
                  "verdict" => "accept",
                  "evidence" => {},
                  "conflicts" => [],
                  "diff" => diff,
                  "record" => record
                }
              ]
            }
          }
        end

        def work_record_hash(title:, key: "OL468431W")
          {
            "key" => {"source" => "openlibrary", "key" => key},
            "redirected_from" => [],
            "title" => title,
            "subtitle" => nil,
            "description" => nil,
            "authors" => [],
            "subjects" => [],
            "year_evidence" => nil,
            "popularity" => nil
          }
        end

        test "returns the existing book without calling any provider when the finder finds one" do
          Providers::OpenLibrary.any_instance.expects(:populate).never
          ::Books::EnrichBookJob.expects(:perform_async).never
          isbn = identifiers(:war_and_peace_isbn13).value

          result = Importer.call(isbn13: [isbn])

          assert result.success?
          assert_equal books_books(:war_and_peace), result.item
        end

        test "creates and persists a new Books::Book end to end when nothing is found" do
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve").to_return(
            status: 200,
            body: accept_response(diff: [
              {"field" => "first_published_year", "ours" => 1925, "theirs" => 1925, "kind" => "agreement"},
              {"field" => "description", "ours" => nil, "theirs" => "A novel set in the Jazz Age", "kind" => "fill"}
            ]).to_json
          )
          # F. Scott Fitzgerald is new, so the book waits for his chain
          # instead of being enriched now (spec §10).
          ::Books::EnrichBookJob.expects(:perform_async).never

          result = Importer.call(title: "The Great Gatsby", author_names: ["F. Scott Fitzgerald"], year: 1925)

          assert result.success?
          assert result.item.persisted?
          assert_equal "The Great Gatsby", result.item.title
          assert_nil result.item.description
          descriptions = result.item.descriptions.where(source: :openlibrary)
          assert_equal 1, descriptions.count
          assert_equal "A novel set in the Jazz Age", descriptions.first.content
          assert_equal "https://openlibrary.org/works/OL468431W", descriptions.first.source_url
          assert_predicate descriptions.first, :license_cc0?
          assert result.item.identifiers.exists?(identifier_type: :books_work_openlibrary_id, value: "OL468431W")
          assert_equal [["skipped", "deferred_to_authors"]], result.item.enrichments.pluck(:outcome, :reason)
        end

        test "importing a new title resolves once: the finder's resolution feeds the provider" do
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: accept_response(diff: []).to_json)

          result = Importer.call(title: "The Great Gatsby", author_names: ["F. Scott Fitzgerald"])

          assert result.success?
          assert result.match.unmatched?
          assert_requested(:post, "#{BASE_URL}/resolve", times: 1)
        end

        test "force_providers runs providers against an existing book" do
          stub_open_library_client
          # war_and_peace already carries a primary description via fixtures
          # (war_and_peace_ai), so a "fill" on description there would be
          # unrealistic -- subtitle is the fixture's genuinely blank field.
          stub_request(:post, "#{BASE_URL}/resolve").to_return(
            status: 200,
            body: accept_response(diff: [
              {"field" => "subtitle", "ours" => nil, "theirs" => "A Novel", "kind" => "fill"}
            ]).to_json
          )
          existing = books_books(:war_and_peace)
          isbn = identifiers(:war_and_peace_isbn13).value

          result = Importer.call(isbn13: [isbn], force_providers: true)

          assert result.success?
          assert_equal existing, result.item
          assert_equal "A Novel", result.item.reload.subtitle
          assert_requested :post, "#{BASE_URL}/resolve", times: 1
        end

        test "identifier-only import persists the query's identifier alongside the accepted OL key, and a second call is idempotent" do
          stub_open_library_client
          new_isbn = "9781234567897"
          stub_request(:post, "#{BASE_URL}/resolve").to_return(
            status: 200,
            body: accept_response(
              diff: [
                {"field" => "title", "ours" => nil, "theirs" => "The Old Man and the Sea", "kind" => "fill"},
                {"field" => "first_published_year", "ours" => nil, "theirs" => 1952, "kind" => "fill"}
              ],
              record: work_record_hash(title: "The Old Man and the Sea")
            ).to_json
          )

          first_result = nil
          assert_difference "::Books::Book.count", 1 do
            first_result = Importer.call(isbn13: [new_isbn])
          end

          assert first_result.success?
          assert first_result.item.persisted?
          assert_equal "The Old Man and the Sea", first_result.item.title
          assert_equal 1952, first_result.item.first_published_year
          assert first_result.item.identifiers.exists?(identifier_type: :books_work_openlibrary_id, value: "OL468431W")
          assert first_result.item.identifiers.exists?(identifier_type: :books_work_isbn13, value: new_isbn)

          second_result = nil
          assert_no_difference "::Books::Book.count" do
            second_result = Importer.call(isbn13: [new_isbn])
          end

          assert second_result.success?
          assert_equal first_result.item, second_result.item
          assert_requested :post, "#{BASE_URL}/resolve", times: 1
        end

        test "no-title guard: an identifier-only import whose diff never fills a title fails without creating a book" do
          stub_open_library_client
          new_isbn = "9780316769488"
          stub_request(:post, "#{BASE_URL}/resolve").to_return(
            status: 200,
            body: accept_response(diff: [
              {"field" => "title", "ours" => nil, "theirs" => nil, "kind" => "absent"}
            ]).to_json
          )

          result = nil
          assert_no_difference "::Books::Book.count" do
            result = Importer.call(isbn13: [new_isbn])
          end

          assert result.failure?
          assert_includes result.all_errors.join, "no title"
          assert_empty ::Identifier.where(identifiable_type: "Books::Book", value: new_isbn)
        end

        test "with Open Library unreachable, an identifier-only import links no orphan author and is not a success" do
          stub_resolve_down
          new_isbn = "9780000000001"

          result = nil
          assert_no_difference ["::Books::Book.count", "::Books::Author.count"] do
            result = Importer.call(isbn13: [new_isbn], author_names: ["Zed Orphanmaker"])
          end

          assert_not result.success?
          assert_not result.item.persisted?
          assert_not ::Books::Author.exists?(name: "Zed Orphanmaker")
        end

        test "R115: a blank isbn13 alongside a real one persists exactly one identifier row" do
          stub_open_library_client
          new_isbn = "9780061120084"
          stub_request(:post, "#{BASE_URL}/resolve").to_return(
            status: 200,
            body: accept_response(
              diff: [
                {"field" => "title", "ours" => nil, "theirs" => "The Old Man and the Sea", "kind" => "fill"},
                {"field" => "first_published_year", "ours" => nil, "theirs" => 1952, "kind" => "fill"}
              ],
              record: work_record_hash(title: "The Old Man and the Sea")
            ).to_json
          )

          result = nil
          assert_difference "::Books::Book.count", 1 do
            result = Importer.call(isbn13: [new_isbn, ""])
          end

          assert result.success?
          assert result.item.persisted?
          assert_equal 1, result.item.identifiers.where(identifier_type: :books_work_isbn13).count
        end

        test "R115: a duplicated isbn13 collapses to exactly one identifier row" do
          stub_open_library_client
          new_isbn = "9780345391803"
          stub_request(:post, "#{BASE_URL}/resolve").to_return(
            status: 200,
            body: accept_response(
              diff: [
                {"field" => "title", "ours" => nil, "theirs" => "The Old Man and the Sea", "kind" => "fill"},
                {"field" => "first_published_year", "ours" => nil, "theirs" => 1952, "kind" => "fill"}
              ],
              record: work_record_hash(title: "The Old Man and the Sea")
            ).to_json
          )

          result = nil
          assert_difference "::Books::Book.count", 1 do
            result = Importer.call(isbn13: [new_isbn, new_isbn])
          end

          assert result.success?
          assert result.item.persisted?
          assert_equal 1, result.item.identifiers.where(identifier_type: :books_work_isbn13).count
        end

        test "an invalid query raises ArgumentError" do
          assert_raises(ArgumentError) { Importer.call(title: nil) }
        end

        test "item: given runs the provider against that item without calling the finder" do
          Finder.any_instance.expects(:call).never
          stub_open_library_client
          # war_and_peace already carries a primary description via fixtures
          # (war_and_peace_ai) -- subtitle is the fixture's genuinely blank
          # field, so a "fill" there is realistic.
          stub_request(:post, "#{BASE_URL}/resolve").to_return(
            status: 200,
            body: accept_response(diff: [
              {"field" => "subtitle", "ours" => nil, "theirs" => "A Novel", "kind" => "fill"}
            ]).to_json
          )
          book = books_books(:war_and_peace)

          result = Importer.call(item: book)

          assert result.success?
          assert_equal book, result.item
          assert_equal "A Novel", result.item.reload.subtitle
        end

        def stub_resolve_down
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 500, body: "{}")
        end

        test "with Open Library unreachable, a title-and-author import creates the book and links an existing author" do
          stub_resolve_down

          result = Importer.call(title: "Hadji Murat", author_names: ["Leo Tolstoy"])

          book = result.item.reload
          assert book.persisted?
          assert_equal [books_authors(:tolstoy)], book.authors.to_a
        end

        test "with Open Library unreachable, book.authors is fresh on the returned item and AI enrichment gets the linked author's name" do
          stub_resolve_down
          ::Books::EnrichBookJob.expects(:perform_async).with(anything, false, ["Leo Tolstoy"])

          result = Importer.call(title: "Hadji Murat", author_names: ["Lev Tolstoy"])

          assert_equal [books_authors(:tolstoy)], result.item.authors.to_a
        end

        test "with Open Library unreachable, a new author name becomes a new author" do
          stub_resolve_down

          book = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"]).item.reload

          assert_equal ["Anna Brenner"], book.authors.map(&:name)
        end

        test "a title-and-author re-import is idempotent" do
          stub_resolve_down
          first = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"]).item

          second = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"])

          assert_equal first, second.item
          assert_equal 1, ::Books::Book.where(title: "The Quiet Year").count
          assert_equal 1, ::Books::Author.where(name: "Anna Brenner").count
        end

        test "provisional saves the new book and the author it creates as provisional" do
          stub_resolve_down

          result = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], provisional: true)

          book = result.item.reload
          assert book.provisional?
          assert book.authors.sole.provisional?
          assert_equal [book.authors.sole.id], result.created_author_ids
        end

        test "provisional never touches an existing author it links" do
          stub_resolve_down

          result = Importer.call(title: "Hadji Murat", author_names: ["Leo Tolstoy"], provisional: true)

          assert_not books_authors(:tolstoy).reload.provisional?
          assert_equal [], result.created_author_ids
        end

        test "without provisional, nothing is provisional" do
          stub_resolve_down

          book = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"]).item.reload

          assert_equal [false, false], [book.provisional?, book.authors.sole.provisional?]
        end

        test "stamp_identifiers stamps the query's identifiers when Open Library is down" do
          stub_resolve_down

          book = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], isbn13: ["9780441013593"],
            goodreads_id: ["234225"], stamp_identifiers: true).item.reload

          assert_equal [["books_work_goodreads_id", "234225"], ["books_work_isbn13", "9780441013593"]],
            book.identifiers.map { |identifier| [identifier.identifier_type, identifier.value] }.sort
        end

        test "without stamp_identifiers, an Open Library outage stamps nothing" do
          stub_resolve_down

          book = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], isbn13: ["9780441013593"]).item.reload

          assert_equal 0, book.identifiers.count
        end

        test "enrich: false runs neither enrichment provider" do
          stub_resolve_down
          ::Books::EnrichBookJob.expects(:perform_async).never
          ::Books::Authors::WikidataJob.expects(:perform_async).never

          result = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], enrich: false)

          assert_equal ["DataImporters::Books::Book::Providers::OpenLibrary", "DataImporters::Books::Book::Providers::Authors"],
            result.provider_results.map(&:provider_name)
        end

        test "a supplied match is used instead of running the finder, and its decision points at the new book" do
          stub_resolve_down
          Finder.any_instance.expects(:call).never
          decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", outcome: :unmatched,
            confidence: :high, decided_by: :rule)
          match = ::DataImporters::Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule, decision: decision)

          result = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"], match: match)

          assert result.created?
          assert_equal result.item, decision.reload.record
        end

        test "an Open Library accept links the work's authors, creating one by its key" do
          stub_open_library_client
          record = work_record_hash(title: "The Quiet Year").merge(
            "authors" => [{"key" => {"source" => "openlibrary", "key" => "OL77A"}, "name" => "Anna Brenner"}]
          )
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: accept_response(diff: [], record: record).to_json)
          stub_request(:get, "#{BASE_URL}/authors/OL77A").to_return(status: 200, body: {
            "source_version" => nil,
            "data" => {"key" => {"source" => "openlibrary", "key" => "OL77A"}, "redirected_from" => [], "name" => "Anna Brenner",
                       "alternate_names" => [], "birth_year" => 1901, "death_year" => nil}
          }.to_json)

          book = Importer.call(title: "The Quiet Year", author_names: ["A. Brenner"]).item.reload

          author = book.authors.sole
          assert_equal ["Anna Brenner", 1901], [author.name, author.birth_year]
          assert author.identifiers.exists?(identifier_type: :books_author_openlibrary_id, value: "OL77A")
        end

        test "a forced re-import of a book that has authors touches neither author step" do
          stub_open_library_client
          record = work_record_hash(title: "War and Peace").merge(
            "authors" => [{"key" => {"source" => "openlibrary", "key" => "OL2A"}, "name" => "Stephen King"}]
          )
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: accept_response(diff: [], record: record).to_json)
          ::DataImporters::Books::Author::Importer.expects(:call).never

          # The ISBN identifier plus the agreeing title corroborates, so the
          # finder matches war_and_peace by rule and stops before its own
          # Open Library source; the forced providers then run with the
          # query, so the Open Library provider (a persisted book) still
          # calls /resolve and reaches link_open_library_authors, and the
          # Authors provider still sees the query's author name.
          result = Importer.call(
            title: "War and Peace", isbn13: [identifiers(:war_and_peace_isbn13).value],
            author_names: ["Stephen King"], force_providers: true
          )

          assert_equal books_books(:war_and_peace), result.item
          assert_equal [books_authors(:tolstoy)], books_books(:war_and_peace).reload.authors.to_a
        end

        test "providers run Open Library, Authors, AI enrichment, then the new authors' chain" do
          providers = Importer.new.send(:providers)

          assert_equal [Providers::OpenLibrary, Providers::Authors, Providers::AiEnrichment, Providers::AuthorEnrichment],
            providers.map(&:class)
        end

        # The race closed by spec §10: the Wikidata step for a new author must
        # see the book among the author's titles, so it is queued only once
        # the book_authors row exists, AND only once the book's own wait is
        # already recorded -- and exactly once, not also from the author
        # importer's own async provider.
        test "a new author's chain starts once, after the book's wait is recorded and its link is saved" do
          stub_resolve_down
          ::Books::EnrichBookJob.expects(:perform_async).never
          ::Books::Authors::WikidataJob.expects(:perform_async)
            .with { |author_id| ::Books::BookAuthor.exists?(author_id: author_id) && ::Enrichment.exists?(reason: "deferred_to_authors") }.once
          ::Books::Authors::WikidataJob.expects(:perform_async)
            .with { |author_id| !::Books::BookAuthor.exists?(author_id: author_id) }.never

          result = Importer.call(title: "The Quiet Year", author_names: ["Anna Brenner"])

          assert_includes result.summary[:data_populated], :ai_enrichment_deferred_to_authors
          assert_equal [["skipped", "deferred_to_authors"]], result.item.enrichments.pluck(:outcome, :reason)
        end

        test "a book whose authors all exist is enriched at once, and no author chain starts" do
          stub_resolve_down
          ::Books::Authors::WikidataJob.expects(:perform_async).never
          ::Books::EnrichBookJob.expects(:perform_async).with(anything, false, ["Leo Tolstoy"])

          result = Importer.call(title: "Hadji Murat", author_names: ["Lev Tolstoy"])

          assert_includes result.summary[:data_populated], :ai_enrichment_queued
        end

        test "a new book is seeded with the query's subtitle, and the finder sends it to /resolve" do
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve")
            .with { |request| JSON.parse(request.body)["subtitle"] == "A Brief History of Humankind" }
            .to_return(status: 200, body: accept_response(diff: []).to_json)

          result = Importer.call(title: "Sapiens", subtitle: "A Brief History of Humankind", author_names: ["Yuval Noah Harari"])

          assert result.item.persisted?
          assert_equal "A Brief History of Humankind", result.item.subtitle
        end

        test "trust_work_key reaches the provider: the chosen key lands on the new book, not the service's" do
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve").to_return(status: 200, body: accept_response(diff: []).to_json)
          match = DataImporters::Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule, candidates: [])

          result = Importer.call(title: "The Chosen", author_names: ["Chaim Potok"], open_library_work_key: "OL5W",
            match: match, trust_work_key: true)

          assert result.item.identifiers.exists?(identifier_type: :books_work_openlibrary_id, value: "OL5W")
          assert_not result.item.identifiers.exists?(identifier_type: :books_work_openlibrary_id, value: "OL468431W")
        end
      end
    end
  end
end

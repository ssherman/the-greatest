# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class ImporterTest < ActiveSupport::TestCase
        BASE_URL = "http://open-library.test:8080"

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

          result = Importer.call(title: "The Great Gatsby", author_names: ["F. Scott Fitzgerald"], year: 1925)

          assert result.success?
          assert result.item.persisted?
          assert_equal "The Great Gatsby", result.item.title
          assert_nil result.item.description
          descriptions = result.item.descriptions.where(source: :openlibrary)
          assert_equal 1, descriptions.count
          assert_equal "A novel set in the Jazz Age", descriptions.first.content
          assert_equal "https://openlibrary.org/works/OL468431W", descriptions.first.source_url
          assert result.item.identifiers.exists?(identifier_type: :books_work_openlibrary_id, value: "OL468431W")
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
      end
    end
  end
end

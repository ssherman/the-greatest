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

        def accept_response(diff:)
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
                  "record" => nil
                }
              ]
            }
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
          assert_equal "A novel set in the Jazz Age", result.item.description
          assert result.item.identifiers.exists?(identifier_type: :books_work_openlibrary_id, value: "OL468431W")
        end

        test "force_providers runs providers against an existing book" do
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve").to_return(
            status: 200,
            body: accept_response(diff: [
              {"field" => "description", "ours" => nil, "theirs" => "Filled description", "kind" => "fill"}
            ]).to_json
          )
          existing = books_books(:war_and_peace)
          isbn = identifiers(:war_and_peace_isbn13).value

          result = Importer.call(isbn13: [isbn], force_providers: true)

          assert result.success?
          assert_equal existing, result.item
          assert_equal "Filled description", result.item.reload.description
          assert_requested :post, "#{BASE_URL}/resolve", times: 1
        end

        test "an invalid query raises ArgumentError" do
          assert_raises(ArgumentError) { Importer.call(title: nil) }
        end

        test "item: given runs the provider against that item without calling the finder" do
          Finder.any_instance.expects(:call).never
          stub_open_library_client
          stub_request(:post, "#{BASE_URL}/resolve").to_return(
            status: 200,
            body: accept_response(diff: [
              {"field" => "description", "ours" => nil, "theirs" => "Filled via item", "kind" => "fill"}
            ]).to_json
          )
          book = books_books(:war_and_peace)

          result = Importer.call(item: book)

          assert result.success?
          assert_equal book, result.item
          assert_equal "Filled via item", result.item.reload.description
        end
      end
    end
  end
end

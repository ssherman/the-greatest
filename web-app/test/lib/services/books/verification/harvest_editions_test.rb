# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class HarvestEditionsTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace)
          @book.update_columns(first_published_year: 1869)
          @row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, new_key: "OL1W", run_id: "r", stage: :identifiers)
          @work = ol_work("OL1W", title: "War and Peace")
        end

        def harvest(editions)
          client = FakeOlClient.new(works: {"OL1W" => @work}, editions: {"OL1W" => editions})
          HarvestEditions.call(verification: @row, client: client)
          @row.reload
        end

        def held(type) = @book.identifiers.where(identifier_type: type).pluck(:value, :source).sort

        test "agreeing editions give work-level ISBNs, OCLC numbers and Goodreads ids as open_library" do
          harvest([ol_edition("OL1M", title: "War and Peace", isbn13: ["978-0-307-26693-4"], isbn10: ["0307266931"], oclc: ["123"], goodreads: ["656"])])

          assert_includes held("books_work_isbn13"), ["9780307266934", "open_library"]
          assert_includes held("books_work_isbn10"), ["0307266931", "open_library"]
          assert_equal [["123", "open_library"]], held("books_work_oclc_id")
          assert_equal [["656", "open_library"]], held("books_work_goodreads_id")
        end

        test "invalid ISBNs are dropped" do
          harvest([ol_edition("OL1M", title: "War and Peace", isbn13: ["9780307266935"], isbn10: ["12345"])])

          refute @book.identifiers.exists?(value: "9780307266935")
          refute @book.identifiers.exists?(value: "12345")
        end

        test "a non-agreeing edition becomes a candidate and writes nothing" do
          harvest([ol_edition("OL2M", title: "Krieg und Frieden", publish_year: 1950, isbn13: ["9783423131681"], language_code: "ger")])

          refute @book.identifiers.exists?(value: "9783423131681")
          candidate = ::Books::EditionCandidate.find_by!(book: @book, edition_key: "OL2M")
          assert_equal ["Krieg und Frieden", "ger", 1950, "OL1W", ["9783423131681"]],
            [candidate.title, candidate.language_code, candidate.publish_year, candidate.work_key, candidate.identifiers["isbn13"]]
        end

        test "the row moves on to worldcat with its counters" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656", source: :legacy)

          row = harvest([
            ol_edition("OL1M", title: "War and Peace", goodreads: ["656"], oclc: ["9"]),
            ol_edition("OL2M", title: "Guerre et paix")
          ])

          assert row.stage_worldcat?
          assert_equal [1, 1, 1], [row.added_count, row.confirmed_count, row.candidate_count]
        end

        test "harvesting again changes nothing" do
          editions = [ol_edition("OL1M", title: "War and Peace", oclc: ["9"]), ol_edition("OL2M", title: "Guerre et paix")]
          harvest(editions)
          @row.update!(stage: :identifiers)

          counts = -> { [Identifier.count, ::Books::VerificationFinding.count, ::Books::EditionCandidate.count] }
          before = counts.call
          harvest(editions)

          assert_equal before, counts.call
        end

        def duplicate(key, source: :open_library)
          Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_duplicate_id, value: key, source: source)
        end

        def harvest_with(works:, editions:)
          client = FakeOlClient.new(works: {"OL1W" => @work}.merge(works), editions: editions)
          HarvestEditions.call(verification: @row, client: client)
          @row.reload
          client
        end

        test "a duplicate work of the same book gives its agreeing editions too, and the rest become candidates" do
          duplicate("OL9W")
          harvest_with(
            works: {"OL9W" => ol_work("OL9W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]])},
            editions: {"OL1W" => [], "OL9W" => [
              ol_edition("OL91M", title: "War and Peace", isbn13: ["9780199232765"]),
              ol_edition("OL92M", title: "Voina i mir", isbn13: ["9785170900541"])
            ]}
          )

          assert_includes held("books_work_isbn13"), ["9780199232765", "open_library"]
          refute @book.identifiers.exists?(value: "9785170900541")
          assert_equal "OL9W", ::Books::EditionCandidate.find_by!(book: @book, edition_key: "OL92M").work_key
        end

        test "a duplicate work that is not the same book is never harvested" do
          duplicate("OL8W")
          client = harvest_with(
            works: {"OL8W" => ol_work("OL8W", title: "Anna Karenina", authors: [["OL1A", "Leo Tolstoy"]])},
            editions: {"OL8W" => [ol_edition("OL81M", title: "War and Peace", isbn13: ["9780199232765"])]}
          )

          refute_includes client.calls, [:editions, "OL8W"]
          refute @book.identifiers.exists?(value: "9780199232765")
        end

        test "a duplicate work that is a volume or part of our title is never harvested" do
          duplicate("OL8W")
          client = harvest_with(
            works: {"OL8W" => ol_work("OL8W", title: "War and Peace", subtitle: "Volume 2", authors: [["OL1A", "Leo Tolstoy"]])},
            editions: {"OL8W" => [ol_edition("OL81M", title: "War and Peace", subtitle: "Volume 2", isbn13: ["9780199232765"])]}
          )

          refute_includes client.calls, [:editions, "OL8W"]
        end

        test "a duplicate work with our title by another author is never harvested" do
          duplicate("OL8W")
          client = harvest_with(
            works: {"OL8W" => ol_work("OL8W", title: "War and Peace", authors: [["OL2A", "Someone Else"]])},
            editions: {"OL8W" => [ol_edition("OL81M", title: "War and Peace", isbn13: ["9780199232765"])]}
          )

          refute_includes client.calls, [:editions, "OL8W"]
        end

        test "a duplicate work our title only reaches by its alternate titles is never harvested" do
          @book.update_columns(alternate_titles: ["Voina i mir"])
          duplicate("OL8W")
          client = harvest_with(
            works: {"OL8W" => ol_work("OL8W", title: "Voina i mir", authors: [["OL1A", "Leo Tolstoy"]])},
            editions: {"OL8W" => [ol_edition("OL81M", title: "Voina i mir", isbn13: ["9785170900541"])]}
          )

          refute_includes client.calls, [:editions, "OL8W"]
        end

        test "a duplicate work another book holds as its work key is never harvested" do
          duplicate("OL8W")
          Identifier.create!(identifiable: books_books(:crime_and_punishment), identifier_type: :books_work_openlibrary_id, value: "OL8W", source: :legacy)
          client = harvest_with(
            works: {"OL8W" => ol_work("OL8W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]])},
            editions: {"OL8W" => [ol_edition("OL81M", title: "War and Peace", isbn13: ["9780199232765"])]}
          )

          refute_includes client.calls, [:editions, "OL8W"]
        end

        test "duplicate keys that redirect to one work, or to the settled work, are harvested once under the live key" do
          duplicate("OL8W")
          duplicate("OL9W")
          duplicate("OL6W")
          tolstoy = [["OL1A", "Leo Tolstoy"]]
          client = harvest_with(
            works: {"OL8W" => ol_work("OL9W", title: "War and Peace", authors: tolstoy),
                    "OL9W" => ol_work("OL9W", title: "War and Peace", authors: tolstoy),
                    "OL6W" => ol_work("OL1W", title: "War and Peace", authors: tolstoy)},
            editions: {"OL9W" => [ol_edition("OL92M", title: "Voina i mir")]}
          )

          assert_equal ["OL1W", "OL9W"], client.calls.filter_map { |name, key| key if name == :editions }
          assert_equal "OL9W", ::Books::EditionCandidate.find_by!(book: @book, edition_key: "OL92M").work_key
        end

        test "a duplicate work Open Library no longer has is skipped and the book moves on" do
          duplicate("OL9W")
          client = FakeOlClient.new(
            works: {"OL1W" => @work, "OL9W" => ol_work("OL9W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]])},
            editions: {"OL1W" => [ol_edition("OL1M", title: "War and Peace", oclc: ["9"])]},
            errors: [nil, nil, ::Books::OpenLibrary::Exceptions::NotFoundError.new("gone", 404)]
          )
          HarvestEditions.call(verification: @row, client: client)

          assert_includes client.calls, [:editions, "OL9W"]
          assert @row.reload.stage_worldcat?
          assert_equal [["9", "open_library"]], held("books_work_oclc_id")
        end

        test "the settled work's own 404 still stops the book at stage 2" do
          client = FakeOlClient.new(works: {"OL1W" => @work}, errors: [nil, ::Books::OpenLibrary::Exceptions::NotFoundError.new("gone", 404)])

          assert_raises(::Books::OpenLibrary::Exceptions::NotFoundError) { HarvestEditions.call(verification: @row, client: client) }
          assert @row.reload.stage_identifiers?
        end

        test "a duplicate key redirecting to a work another book holds as its work key is never harvested" do
          duplicate("OL8W")
          Identifier.create!(identifiable: books_books(:crime_and_punishment), identifier_type: :books_work_openlibrary_id, value: "OL5W", source: :legacy)
          client = harvest_with(
            works: {"OL8W" => ol_work("OL5W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]])},
            editions: {"OL5W" => [ol_edition("OL51M", title: "War and Peace", isbn13: ["9780199232765"])]}
          )

          refute_includes client.calls, [:editions, "OL5W"]
        end

        test "a duplicate key Open Library did not give us is never harvested" do
          duplicate("OL7W", source: :legacy)
          client = harvest_with(
            works: {"OL7W" => ol_work("OL7W", title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]])},
            editions: {"OL7W" => [ol_edition("OL71M", title: "War and Peace", isbn13: ["9780199232765"])]}
          )

          refute_includes client.calls, [:editions, "OL7W"]
          refute @book.identifiers.exists?(value: "9780199232765")
        end

        test "at most MAX_DUPLICATE_WORKS duplicate works are harvested, oldest first" do
          keys = (1..HarvestEditions::MAX_DUPLICATE_WORKS + 1).map { |n| "OL#{100 + n}W" }
          keys.each { |key| duplicate(key) }
          client = harvest_with(works: keys.to_h { |key| [key, ol_work(key, title: "War and Peace", authors: [["OL1A", "Leo Tolstoy"]])] }, editions: {})

          fetched = client.calls.filter_map { |name, key| key if name == :editions } - ["OL1W"]
          assert_equal keys.first(HarvestEditions::MAX_DUPLICATE_WORKS), fetched
        end

        test "an Open Library error writes nothing and leaves the stage" do
          client = FakeOlClient.new(works: {"OL1W" => @work}, errors: [nil, ::Books::OpenLibrary::Exceptions::TimeoutError.new("slow")])

          assert_raises(::Books::OpenLibrary::Exceptions::TimeoutError) { HarvestEditions.call(verification: @row, client: client) }
          assert @row.reload.stage_identifiers?
        end
      end
    end
  end
end

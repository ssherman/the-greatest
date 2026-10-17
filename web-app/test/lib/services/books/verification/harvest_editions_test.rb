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

        test "an Open Library error writes nothing and leaves the stage" do
          client = FakeOlClient.new(works: {"OL1W" => @work}, errors: [nil, ::Books::OpenLibrary::Exceptions::TimeoutError.new("slow")])

          assert_raises(::Books::OpenLibrary::Exceptions::TimeoutError) { HarvestEditions.call(verification: @row, client: client) }
          assert @row.reload.stage_identifiers?
        end
      end
    end
  end
end

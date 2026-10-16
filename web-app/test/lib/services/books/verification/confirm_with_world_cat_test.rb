# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class ConfirmWithWorldCatTest < ActiveSupport::TestCase
        include OlBackfillHelper

        ISBN13 = "9780307266934"
        ISBN10 = "0307266931"

        setup do
          @book = books_books(:war_and_peace) # holds 9780140447934 (fixture, nil source)
          @book.update_columns(first_published_year: 1869)
          @row = ::Books::Verification.create!(book: @book, work_outcome: :unsure, run_id: "r", stage: :worldcat)
        end

        def agreeing(oclc: 77) = wc_record(oclc: oclc, title: "War and peace", creator: "Tolstoy, Leo", year: 2007)

        def confirm(records)
          ConfirmWithWorldCat.call(verification: @row, client: FakeWcClient.new(records: records), dump_date: "2025-09-04")
          @row.reload
        end

        test "an agreeing record confirms both forms of the ISBN as worldcat and adds its OCLC number" do
          isbn13 = Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :legacy)
          isbn10 = Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn10, value: ISBN10, source: :legacy)

          row = confirm(ISBN13 => [agreeing])

          assert isbn13.reload.source_worldcat?
          assert isbn10.reload.source_worldcat?
          assert_equal "worldcat", @book.identifiers.find_by!(identifier_type: :books_work_oclc_id, value: "77").source
          assert_equal [2, 1], [row.confirmed_count, row.added_count]
          assert row.stage_signals?
          assert_equal "2025-09-04", row.worldcat_dump_date
        end

        test "records that all clearly differ make a wrong_identifier finding and remove nothing" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :legacy)

          row = confirm(ISBN13 => [wc_record(oclc: 5, title: "Gloriana", creator: "Moorcock, Michael", year: 1978)])

          assert @book.identifiers.exists?(value: ISBN13)
          finding = row.findings.find_by!(kind: :wrong_identifier)
          assert_equal [ISBN13, "Gloriana"], [finding.value, finding.evidence["records"].first["title"]]
          assert_equal 1, row.wrong_count
        end

        test "a record disagreeing on one side only, or no record, changes nothing" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :legacy)

          row = confirm(ISBN13 => [wc_record(oclc: 5, title: "Gloriana", creator: "Leo Tolstoy", year: 2007)])

          assert_empty row.findings
          assert row.stage_signals?
        end

        test "verified ISBNs are not looked up; the fixture's unmarked one is" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :open_library)
          client = FakeWcClient.new

          ConfirmWithWorldCat.call(verification: @row, client: client, dump_date: "2025-09-04")

          assert_equal [[:record_by_isbn, "9780140447934"]], client.calls
        end

        test "the lookup cap is 50 and is applied" do
          assert_equal 50, ConfirmWithWorldCat::MAX_WORLDCAT_ISBNS
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :legacy)
          client = FakeWcClient.new
          ConfirmWithWorldCat.stubs(:max_isbns).returns(1)

          ConfirmWithWorldCat.call(verification: @row, client: client, dump_date: "2025-09-04")

          assert_equal 1, client.calls.size
        end

        test "a WorldCat error writes nothing and leaves the stage" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :legacy)
          client = FakeWcClient.new(errors: [::Books::WorldCat::Exceptions::TimeoutError.new("slow")])

          assert_raises(::Books::WorldCat::Exceptions::TimeoutError) { ConfirmWithWorldCat.call(verification: @row, client: client, dump_date: "x") }
          assert @row.reload.stage_worldcat?
        end
      end
    end
  end
end

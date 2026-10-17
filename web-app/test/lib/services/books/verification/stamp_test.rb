# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class StampTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @other = books_books(:crime_and_punishment)
          @row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, run_id: "r")
        end

        def stamp(value, source: :open_library) = Stamp.call(verification: @row, type: "books_work_isbn13", value: value, source: source, evidence: {"edition_key" => "OL1M"})

        def finding(kind, value) = @row.findings.find_by(kind: kind, value: value)

        test "a value nobody holds is added with an added finding" do
          assert_equal :added, stamp("9780000000017")

          identifier = @book.identifiers.find_by!(identifier_type: :books_work_isbn13, value: "9780000000017")
          assert identifier.source_open_library?
          assert_equal [identifier.id, "OL1M"], [finding(:added, "9780000000017").identifier_id, finding(:added, "9780000000017").evidence["edition_key"]]
        end

        test "a legacy value the book holds is confirmed in place, its old source logged" do
          held = Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780000000017", source: :legacy)

          assert_equal :confirmed, stamp("9780000000017")

          assert held.reload.source_open_library?
          assert_equal "legacy", finding(:confirmed, "9780000000017").previous_source
        end

        test "an unmarked (nil) value the book holds is confirmed too" do
          held = identifiers(:war_and_peace_isbn13)

          assert_equal :confirmed, stamp(held.value)
          assert held.reload.source_open_library?
        end

        test "a value the book holds verified is left alone with no finding" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780000000017", source: :worldcat)

          assert_equal :unchanged, stamp("9780000000017")
          assert_empty @row.findings
        end

        test "a value another book holds verified is not written: conflict" do
          Identifier.create!(identifiable: @other, identifier_type: :books_work_isbn13, value: "9780000000017", source: :worldcat)

          assert_equal :conflict, stamp("9780000000017")

          refute @book.identifiers.exists?(value: "9780000000017")
          assert_equal @other.id, finding(:conflict, "9780000000017").other_book_id
        end

        test "a value another book holds unverified is written here and flagged also_held; the other book is untouched" do
          theirs = Identifier.create!(identifiable: @other, identifier_type: :books_work_isbn13, value: "9780000000017", source: :legacy)

          assert_equal :added, stamp("9780000000017")

          assert @book.identifiers.exists?(value: "9780000000017")
          assert_equal @other.id, finding(:also_held, "9780000000017").other_book_id
          assert theirs.reload.source_legacy?
        end

        test "stamping twice writes one identifier and one finding" do
          stamp("9780000000017")
          stamp("9780000000017")

          assert_equal 1, @book.identifiers.where(value: "9780000000017").count
          assert_equal 1, @row.findings.where(value: "9780000000017").count
        end
      end
    end
  end
end

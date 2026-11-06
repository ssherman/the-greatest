# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class BookIdentifierWriterTest < ActiveSupport::TestCase
      test "a write sets the given source on new rows" do
        book = books_books(:war_and_peace)
        result = BookIdentifierWriter.call(book: book, pairs: [["books_work_goodreads_id", "12345"]], source: :goodreads)
        assert_equal [["books_work_goodreads_id", "12345"]], result.written
        assert_empty result.flagged_book_ids
        assert book.identifiers.exists?(identifier_type: :books_work_goodreads_id, value: "12345", source: :goodreads)
      end

      test "a verified conflict in the ISBN-10 form flags the holder and writes nothing" do
        other = ::Books::Book.create!(title: "Other")
        other.identifiers.create!(identifier_type: :books_work_isbn10, value: "1400079985", source: :open_library)
        book = books_books(:war_and_peace)
        result = nil
        assert_difference "::DuplicateCandidate.count", 1 do
          result = BookIdentifierWriter.call(book: book, pairs: [["books_work_isbn13", "9781400079988"]], source: :goodreads, evidence: {"goodreads_id" => "9"})
        end
        assert_empty result.written
        assert_equal [other.id], result.flagged_book_ids
        refute book.identifiers.exists?(value: "9781400079988")
        evidence = ::DuplicateCandidate.order(:id).last.evidence
        assert_equal "9", evidence["goodreads_id"]
        assert evidence["conflicts"].present?
      end

      test "an unverified holder does not block the write" do
        other = ::Books::Book.create!(title: "Other")
        other.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :legacy)
        book = books_books(:war_and_peace)
        assert_no_difference "::DuplicateCandidate.count" do
          result = BookIdentifierWriter.call(book: book, pairs: [["books_work_isbn13", "9781400079988"]], source: :goodreads)
          assert_equal 1, result.written.size
        end
      end

      test "a re-run creates no duplicates" do
        book = books_books(:war_and_peace)
        pairs = [["books_work_goodreads_id", "12345"]]
        BookIdentifierWriter.call(book: book, pairs: pairs, source: :goodreads)
        assert_no_difference "::Identifier.count" do
          BookIdentifierWriter.call(book: book, pairs: pairs, source: :goodreads)
        end
      end
    end
  end
end

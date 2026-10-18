# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class AmazonBookIdentifiersTest < ActiveSupport::TestCase
      test "writes ASIN, ISBN-13 and ISBN-10 to the book with source amazon" do
        book = books_books(:war_and_peace)
        AmazonBookIdentifiers.call(book: book, product: product(asin: "B000FC0PDA", isbns: ["9781400079988", "1400079985"]))
        rows = book.identifiers.where(identifier_type: %w[books_work_asin books_work_isbn13 books_work_isbn10], source: :amazon)
        assert_equal [["books_work_asin", "B000FC0PDA"], ["books_work_isbn10", "1400079985"], ["books_work_isbn13", "9781400079988"]],
          rows.pluck(:identifier_type, :value).sort
      end

      test "a 978 EAN is written as ISBN-13; any other EAN and any bad checksum are not" do
        book = books_books(:war_and_peace)
        AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9781400079980"], eans: ["9781400079988", "4006381333931"]))
        assert book.identifiers.exists?(identifier_type: :books_work_isbn13, value: "9781400079988", source: :amazon)
        refute book.identifiers.exists?(value: "9781400079980")
        refute ::Identifier.exists?(value: "4006381333931", identifiable_type: "Books::Book")
      end

      test "a value already on the book keeps its row and its source; a re-run adds nothing" do
        book = books_books(:war_and_peace)
        existing = identifiers(:war_and_peace_isbn13)
        assert_no_difference "::Identifier.count" do
          2.times { AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9780140447934"])) }
        end
        assert_nil existing.reload.source
      end

      test "a value held by another book with an unverified source is still written" do
        other = ::Books::Book.create!(title: "Other")
        other.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :legacy)
        book = books_books(:war_and_peace)
        result = nil
        assert_no_difference "::DuplicateCandidate.count" do
          result = AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9781400079988"]))
        end
        assert book.identifiers.exists?(identifier_type: :books_work_isbn13, value: "9781400079988")
        assert_empty result.flagged_book_ids
      end

      test "a value held verified by another book writes none of the product's values and flags the pair once" do
        other = ::Books::Book.create!(title: "Other")
        other.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :worldcat)
        book = books_books(:war_and_peace)
        p = product(asin: "B000FC0PDA", isbns: ["9781400079988", "1400079985"])

        assert_no_difference "book.identifiers.count" do
          2.times { AmazonBookIdentifiers.call(book: book, product: p) }
        end
        candidate = pair_candidates(book, other).sole
        assert_equal ["Books::Book", "identifier_collision", "pending", 2],
          [candidate.item_type, candidate.source, candidate.status, candidate.occurrences]
        assert_equal [book.id, other.id].sort, [candidate.item_a_id, candidate.item_b_id]
        assert_equal "B000FC0PDA", candidate.evidence["amazon_asin"]
      end

      test "a pair already marked not_duplicate stays closed" do
        other = ::Books::Book.create!(title: "Other")
        other.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :open_library)
        book = books_books(:war_and_peace)
        a, b = [book.id, other.id].minmax
        ::DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: a, item_b_id: b, source: :identifier_collision, status: :not_duplicate, evidence: {})
        AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9781400079988"]))
        assert pair_candidates(book, other).sole.not_duplicate?
      end

      private

      def pair_candidates(book, other)
        a, b = [book.id, other.id].minmax
        ::DuplicateCandidate.where(item_type: "Books::Book", item_a_id: a, item_b_id: b)
      end

      def product(asin:, isbns: [], eans: [])
        {
          "asin" => asin,
          "itemInfo" => {
            "title" => {"displayValue" => "War and Peace"},
            "externalIds" => {
              "isbns" => {"displayValues" => isbns},
              "eans" => {"displayValues" => eans}
            }
          }
        }
      end
    end
  end
end

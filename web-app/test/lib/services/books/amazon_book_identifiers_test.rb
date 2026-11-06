# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class AmazonBookIdentifiersTest < ActiveSupport::TestCase
      test "writes ASIN, ISBN-13 and ISBN-10 to the book with source amazon" do
        book = books_books(:war_and_peace)
        result = AmazonBookIdentifiers.call(book: book, product: product(asin: "B000FC0PDA", isbns: ["9781400079988", "1400079985"]))
        assert_equal [["books_work_asin", "B000FC0PDA"], ["books_work_isbn13", "9781400079988"], ["books_work_isbn10", "1400079985"]], result.written
        assert_empty result.flagged_book_ids
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

        result = nil
        assert_no_difference "book.identifiers.count" do
          2.times { result = AmazonBookIdentifiers.call(book: book, product: p) }
        end
        assert_equal [other.id], result.flagged_book_ids
        assert_empty result.written
        candidate = pair_candidates(book, other).sole
        assert_equal ["Books::Book", "identifier_collision", "pending", 2],
          [candidate.item_type, candidate.source, candidate.status, candidate.occurrences]
        assert_equal [book.id, other.id].sort, [candidate.item_a_id, candidate.item_b_id]
        assert_equal "B000FC0PDA", candidate.evidence["amazon_asin"]
        assert_equal "War and Peace", candidate.evidence["amazon_title"]
        # The product's ISBN-10 is the same publication as the held ISBN-13, so it conflicts too.
        assert_equal [
          {"identifier_type" => "books_work_isbn13", "value" => "9781400079988", "holder_book_id" => other.id, "holder_source" => "worldcat"},
          {"identifier_type" => "books_work_isbn10", "value" => "1400079985", "holder_book_id" => other.id, "holder_source" => "worldcat"}
        ], candidate.evidence["conflicts"]
      end

      test "two verified holders are flagged separately, each with only its own conflict, and nothing is written" do
        holder_a = ::Books::Book.create!(title: "Holder A")
        holder_a.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :worldcat)
        holder_b = ::Books::Book.create!(title: "Holder B")
        holder_b.identifiers.create!(identifier_type: :books_work_isbn13, value: "9780316769488", source: :open_library)
        book = books_books(:war_and_peace)

        result = nil
        assert_no_difference "book.identifiers.count" do
          result = AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9781400079988", "9780316769488"]))
        end

        assert_equal [holder_a.id, holder_b.id].sort, result.flagged_book_ids.sort
        assert_empty result.written
        conflicts_a = pair_candidates(book, holder_a).sole.evidence["conflicts"]
        conflicts_b = pair_candidates(book, holder_b).sole.evidence["conflicts"]
        assert_equal [["books_work_isbn13", "9781400079988", holder_a.id]], conflicts_a.map { |c| c.values_at("identifier_type", "value", "holder_book_id") }
        assert_equal [["books_work_isbn13", "9780316769488", holder_b.id]], conflicts_b.map { |c| c.values_at("identifier_type", "value", "holder_book_id") }
      end

      test "a pair already marked not_duplicate stays closed" do
        other = ::Books::Book.create!(title: "Other")
        other.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :open_library)
        book = books_books(:war_and_peace)
        a, b = [book.id, other.id].minmax
        ::DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: a, item_b_id: b, source: :identifier_collision, status: :not_duplicate, evidence: {})
        AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9781400079988"]))
        assert pair_candidates(book, other).sole.not_duplicate?
        refute book.identifiers.exists?(value: "9781400079988")
      end

      test "a verified ISBN-13 elsewhere blocks the same ISBN arriving only as ISBN-10, and the reverse" do
        book = books_books(:war_and_peace)
        holder13 = ::Books::Book.create!(title: "Holder 13")
        holder13.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :worldcat)

        result = AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["1400079985"]))

        assert_equal [holder13.id], result.flagged_book_ids
        refute book.identifiers.exists?(value: "1400079985")
        assert_equal [["books_work_isbn10", "1400079985"]],
          pair_candidates(book, holder13).sole.evidence["conflicts"].map { |c| c.values_at("identifier_type", "value") }

        holder10 = ::Books::Book.create!(title: "Holder 10")
        holder10.identifiers.create!(identifier_type: :books_work_isbn10, value: "0140447938", source: :open_library)

        result = AmazonBookIdentifiers.call(book: book, product: product(asin: nil, isbns: ["9780140447934"]))

        assert_equal [holder10.id], result.flagged_book_ids
      end

      test "a physical book's ASIN that is an ISBN-10 is checked against verified ISBNs too" do
        book = books_books(:war_and_peace)
        holder = ::Books::Book.create!(title: "Holder")
        holder.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :worldcat)

        result = AmazonBookIdentifiers.call(book: book, product: product(asin: "1400079985"))

        assert_equal [holder.id], result.flagged_book_ids
        refute book.identifiers.exists?(value: "1400079985")
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

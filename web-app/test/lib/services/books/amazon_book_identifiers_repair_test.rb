# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class AmazonBookIdentifiersRepairTest < ActiveSupport::TestCase
      ASIN = "1400079985"
      ISBN13 = "9781400079988"

      setup do
        @book = books_books(:war_and_peace)
      end

      # What the enrichment stores on an edition (lowerCamelCase).
      def product(authors: ["Tolstoy, Leo"], title: "War and Peace (Vintage Classics)", asin: ASIN, isbns: [ISBN13])
        {
          "asin" => asin,
          "itemInfo" => {
            "title" => {"displayValue" => title},
            "byLineInfo" => {"contributors" => authors.map { |name| {"name" => name, "role" => "Author"} }},
            "contentInfo" => {"publicationDate" => {"displayValue" => "2008-10-14T00:00:01Z"}},
            "externalIds" => {"isbns" => {"displayValues" => isbns}}
          }
        }
      end

      def edition(book: @book, amazon: product)
        ::Books::Edition.create!(book: book, edition_type: :standard, metadata: {"amazon" => amazon})
      end

      def held?(type, value, book: @book) = book.identifiers.exists?(identifier_type: type, value: value)

      test "a Last, First credit on the same book puts the ASIN and ISBN on the book, from amazon" do
        edition

        data = AmazonBookIdentifiersRepair.call(dry_run: false).data

        assert held?(:books_work_asin, ASIN)
        assert held?(:books_work_isbn13, ISBN13)
        assert_equal ["amazon"], @book.identifiers.where(value: [ASIN, ISBN13]).distinct.pluck(:source).map(&:to_s)
        assert_equal [1, 1, 1, 2, 0, true], data.values_at(:checked, :same_book, :editions_written, :identifiers_written, :editions_flagged, :done)
      end

      test "a dry run counts what it would write and writes nothing" do
        edition

        data = AmazonBookIdentifiersRepair.call(dry_run: true).data

        refute held?(:books_work_asin, ASIN)
        assert_equal [1, 2], data.values_at(:editions_written, :identifiers_written)
      end

      test "a rerun writes nothing new" do
        edition
        AmazonBookIdentifiersRepair.call(dry_run: false)

        assert_no_difference "::Identifier.count" do
          data = AmazonBookIdentifiersRepair.call(dry_run: false).data
          assert_equal [1, 0, 0], data.values_at(:same_book, :editions_written, :identifiers_written)
        end
      end

      test "another author, another title, and a set are checked and left alone" do
        [product(authors: ["Else, Someone"]), product(title: "Anna Karenina"), product(title: "War and Peace (Boxed Set)")].each { |amazon| edition(amazon: amazon) }

        data = AmazonBookIdentifiersRepair.call(dry_run: false).data

        refute held?(:books_work_asin, ASIN)
        assert_equal [3, 0], data.values_at(:checked, :same_book)
      end

      test "only editions our enrichment wrote with a comma in an author credit are looked at" do
        edition(amazon: product(authors: ["Leo Tolstoy"]))
        edition(amazon: {"ASIN" => ASIN, "ItemInfo" => {"ByLineInfo" => {"Contributors" => [{"Name" => "Tolstoy, Leo", "Role" => "Author"}]}}})
        comma = edition

        assert_equal [comma.id], AmazonBookIdentifiersRepair.scope.pluck(:id)
      end

      test "a value another book holds from a verified source flags the pair, writes nothing, and a dry run flags nothing" do
        other = ::Books::Book.create!(title: "Other")
        other.identifiers.create!(identifier_type: :books_work_isbn13, value: ISBN13, source: :open_library)
        edition

        assert_no_difference "::DuplicateCandidate.count" do
          assert_equal 1, AmazonBookIdentifiersRepair.call(dry_run: true).data[:editions_flagged]
        end
        assert_difference "::DuplicateCandidate.count", 1 do
          data = AmazonBookIdentifiersRepair.call(dry_run: false).data
          assert_equal [1, 0], data.values_at(:editions_flagged, :editions_written)
        end
        refute held?(:books_work_asin, ASIN)
      end

      test "chunks walk the editions in id order after after_id, and the last chunk says done" do
        first = edition
        second = edition(amazon: product(asin: "B000000002", isbns: []))

        chunk = AmazonBookIdentifiersRepair.call(after_id: 0, limit: 1, dry_run: false).data
        assert_equal [first.id, false, 1], chunk.values_at(:last_id, :done, :checked)

        chunk = AmazonBookIdentifiersRepair.call(after_id: chunk[:last_id], limit: 1, dry_run: false).data
        assert_equal [second.id, 1], chunk.values_at(:last_id, :checked)
        assert held?(:books_work_asin, "B000000002")

        chunk = AmazonBookIdentifiersRepair.call(after_id: chunk[:last_id], limit: 1, dry_run: false).data
        assert_equal [second.id, true, 0], chunk.values_at(:last_id, :done, :checked)
      end
    end
  end
end

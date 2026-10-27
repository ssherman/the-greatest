# frozen_string_literal: true

module Services
  module Books
    # Puts an Amazon product's ASIN and ISBNs on the BOOK, not just on its
    # edition. The caller has already proven the product is exactly this book
    # (AmazonBookCheck.same_book?); this class only builds the pairs;
    # BookIdentifierWriter decides whether they are safe to write.
    class AmazonBookIdentifiers
      def self.call(book:, product:)
        new(book: book, product: product).call
      end

      def initialize(book:, product:)
        @book = book
        @product = product
      end

      def call
        pairs = identifier_pairs
        BookIdentifierWriter.call(
          book: @book, pairs: pairs, source: :amazon,
          evidence: {
            "amazon_asin" => @product["asin"],
            "amazon_title" => @product.dig("itemInfo", "title", "displayValue")
          }
        )
      end

      private

      def identifier_pairs
        pairs = []
        asin = @product["asin"].presence
        pairs << ["books_work_asin", asin] if asin

        display_values("isbns").each do |raw|
          normalized = ::Books::Isbn.normalize(raw)
          next if normalized.nil?

          case raw.to_s.gsub(/[^0-9A-Za-z]/, "").length
          when 13 then pairs << ["books_work_isbn13", normalized.isbn13]
          when 10 then pairs << ["books_work_isbn10", normalized.isbn10]
          end
        end

        # An EAN is any retail barcode; only a Bookland one (978/979) is an ISBN.
        display_values("eans").each do |raw|
          normalized = ::Books::Isbn.normalize(raw)
          next if normalized.nil? || !normalized.isbn13.start_with?("978", "979")

          pairs << ["books_work_isbn13", normalized.isbn13]
        end

        pairs.uniq
      end

      def display_values(kind)
        Array(@product.dig("itemInfo", "externalIds", kind, "displayValues"))
      end
    end
  end
end

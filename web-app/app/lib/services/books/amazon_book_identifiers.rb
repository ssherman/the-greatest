# frozen_string_literal: true

module Services
  module Books
    # Puts an Amazon product's ASIN and ISBNs on the BOOK, not just on its
    # edition. The caller has already proven the product is exactly this book
    # (AmazonBookCheck.same_book?); this class only decides whether the values
    # are safe to write. Every other identifier on a book is trusted by the
    # duplicate-reduction work, so one wrong value is worse than a missing one:
    # when another book already holds any of these values from a verified source
    # (Open Library, WorldCat), NOTHING is written and the pair is flagged for a
    # human instead. A value held by another book from an unverified source does
    # not block the write, because that holder is as likely to be the wrong one.
    class AmazonBookIdentifiers
      Result = Struct.new(:written, :flagged_book_ids, keyword_init: true)

      def self.call(book:, product:)
        new(book: book, product: product).call
      end

      def initialize(book:, product:)
        @book = book
        @product = product
      end

      def call
        pairs = identifier_pairs
        conflicts = verified_conflicts(pairs)
        return flag(conflicts) if conflicts.any?

        written = []
        ::Identifier.transaction do
          pairs.each do |type, value|
            row = @book.identifiers.find_or_initialize_by(identifier_type: type, value: value)
            row.source = :amazon if row.new_record?
            row.save!
            written << [type, value]
          end
        end
        Result.new(written: written, flagged_book_ids: [])
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

      def verified_conflicts(pairs)
        pairs.flat_map do |type, value|
          ::Identifier.where(identifiable_type: "Books::Book", identifier_type: type, value: value)
            .where.not(identifiable_id: @book.id).verified
            .map { |row| {"identifier_type" => type, "value" => value, "holder_book_id" => row.identifiable_id, "holder_source" => row.source} }
        end
      end

      def flag(conflicts)
        by_holder = conflicts.group_by { |conflict| conflict["holder_book_id"] }
        by_holder.each do |holder_id, holder_conflicts|
          ::Services::DuplicateCandidates::Flag.call(
            item_type: "Books::Book",
            ids: [@book.id, holder_id],
            source: :identifier_collision,
            evidence: {
              "amazon_asin" => @product["asin"],
              "amazon_title" => @product.dig("itemInfo", "title", "displayValue"),
              "conflicts" => holder_conflicts
            },
            match_decision: nil
          )
        end
        Result.new(written: [], flagged_book_ids: by_holder.keys)
      end
    end
  end
end

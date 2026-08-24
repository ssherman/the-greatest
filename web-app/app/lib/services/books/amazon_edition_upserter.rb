# frozen_string_literal: true

module Services
  module Books
    # Turns one validated Amazon product into a Books::Edition of the given book.
    #
    # Identity is the edition-level ASIN identifier, falling back to ISBN-13 and
    # then EAN-13, ALWAYS scoped to the book: the legacy data has 2,149 ASINs
    # attached to more than one book, so a global lookup would hang editions off
    # the wrong work. The ISBN fallback is what keeps an Amazon reissue under a
    # fresh ASIN from creating a second edition of the same printing.
    #
    # Write rules: sales rank and the raw metadata always refresh, because they
    # are inherently live. Everything descriptive is written only when blank --
    # admins can hand-edit every one of those columns, and a blind refresh would
    # silently revert their corrections across 148,296 rows.
    class AmazonEditionUpserter
      Result = Struct.new(:edition, :created, keyword_init: true)

      # Amazon binding display value (downcased) -> Books::Edition#book_binding
      BINDINGS = {
        "hardcover" => :hardcover,
        "paperback" => :paperback,
        "mass market paperback" => :mass_market,
        "kindle edition" => :ebook,
        "ebook" => :ebook,
        "audible audiobook" => :audiobook,
        "audio cd" => :audiobook,
        "mp3 cd" => :audiobook,
        "library binding" => :library_binding,
        "leather bound" => :leather_bound,
        "imitation leather" => :leather_bound
      }.freeze

      def self.call(book:, product:)
        new(book: book, product: product).call
      end

      def initialize(book:, product:)
        @book = book
        @product = product
      end

      def call
        edition = find_edition || book.editions.build(edition_type: :standard)
        created = edition.new_record?

        apply_volatile(edition)
        apply_descriptive(edition)
        edition.save!

        write_identifiers(edition)

        Result.new(edition: edition, created: created)
      end

      private

      attr_reader :book, :product

      # ---- identity ------------------------------------------------------

      def find_edition
        edition_by(:books_edition_asin, [asin]) ||
          edition_by(:books_edition_isbn13, isbns.select { |v| v.length == 13 }) ||
          edition_by(:books_edition_ean13, eans)
      end

      # order(:id) so the 2,747 legacy in-book duplicate groups resolve the same
      # way on every run instead of picking an arbitrary row.
      def edition_by(identifier_type, values)
        values = Array(values).compact_blank
        return nil if values.empty?

        edition_ids = Identifier.where(
          identifiable_type: "Books::Edition",
          identifier_type: identifier_type,
          value: values
        ).pluck(:identifiable_id)
        return nil if edition_ids.empty?

        book.editions.where(id: edition_ids).order(:id).first
      end

      # ---- writes --------------------------------------------------------

      def apply_volatile(edition)
        edition.popularity = product.dig("browseNodeInfo", "websiteSalesRank", "salesRank")
        edition.metadata = (edition.metadata || {}).merge("amazon" => product)
      end

      def apply_descriptive(edition)
        title, subtitle = split_title(product.dig("itemInfo", "title", "displayValue"))

        edition.title = title if edition.title.blank? && title.present?
        edition.subtitle = subtitle if edition.subtitle.blank? && subtitle.present?
        edition.book_binding = book_binding if edition.book_binding.blank? && book_binding.present?
        edition.publisher_name = publisher_name if edition.publisher_name.blank? && publisher_name.present?
        edition.publication_year = publication_year if edition.publication_year.blank? && publication_year.present?
        edition.page_count = page_count if edition.page_count.blank? && page_count.present?
        edition.language = language if edition.language_id.blank? && language.present?
      end

      def write_identifiers(edition)
        upsert_identifier(edition, :books_edition_asin, asin)

        isbns.each do |isbn|
          upsert_identifier(edition, (isbn.length == 13) ? :books_edition_isbn13 : :books_edition_isbn10, isbn)
        end

        eans.each { |ean| upsert_identifier(edition, :books_edition_ean13, ean) }
      end

      def upsert_identifier(edition, identifier_type, value)
        return if value.blank?

        edition.identifiers
          .find_or_initialize_by(identifier_type: identifier_type, value: value)
          .save!
      end

      # ---- product reads --------------------------------------------------

      def asin
        product["asin"].presence
      end

      def isbns
        Array(product.dig("itemInfo", "externalIds", "isbns", "displayValues"))
          .map(&:to_s)
          .select { |value| [10, 13].include?(value.length) }
      end

      def eans
        Array(product.dig("itemInfo", "externalIds", "eans", "displayValues"))
          .map(&:to_s)
          .select { |value| value.length == 13 }
      end

      def publisher_name
        product.dig("itemInfo", "byLineInfo", "manufacturer", "displayValue").presence
      end

      def page_count
        product.dig("itemInfo", "contentInfo", "pagesCount", "displayValue")
      end

      def publication_year
        product.dig("itemInfo", "contentInfo", "publicationDate", "displayValue").to_s[/\d{4}/]&.to_i
      end

      # An unmapped binding must never raise -- one odd string would otherwise
      # abort a multi-day sweep.
      def book_binding
        return @book_binding if defined?(@book_binding)

        raw = product.dig("itemInfo", "classifications", "binding", "displayValue")
        @book_binding = if raw.blank?
          nil
        else
          BINDINGS.fetch(raw.to_s.strip.downcase) do
            Rails.logger.info "Unmapped Amazon binding #{raw.inspect}; storing as :other"
            :other
          end
        end
      end

      # Amazon returns several language entries per product; only the "Published"
      # one describes this printing. Never creates a Language row.
      def language
        return @language if defined?(@language)

        entries = Array(product.dig("itemInfo", "contentInfo", "languages", "displayValues"))
        name = entries.find { |entry| entry["type"] == "Published" }&.dig("displayValue")
        @language = name.blank? ? nil : Language.find_by(name: name)
      end

      # Legacy's process_title: drop parenthesised and bracketed noise, then split
      # the first colon into title and subtitle.
      def split_title(raw)
        return [nil, nil] if raw.blank?

        cleaned = raw.gsub(/\s*[(\[][^)\]]*[)\]]\s*/, " ").squeeze(" ").strip
        head, tail = cleaned.split(":", 2)
        [head&.strip.presence, tail&.strip.presence]
      end
    end
  end
end

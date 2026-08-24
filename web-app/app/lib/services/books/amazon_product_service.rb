# frozen_string_literal: true

module Services
  module Books
    # Amazon enrichment for books.
    #
    # Unlike music and games, where a validated match is just an ExternalLink, a
    # books match is a Books::Edition: an Amazon book product IS a specific
    # printing, with its own ISBN, binding, publisher and page count. The buy
    # link and the cover hang off that edition.
    class AmazonProductService < ::Services::Amazon::BaseProductService
      # Audible. The plain Books search never surfaces audiobooks, so legacy ran
      # a second pass against this node and so do we.
      AUDIBLE_BROWSE_NODE = "18145289011"

      AMAZON_RESOURCES = (
        ::Services::Amazon::BaseProductService::AMAZON_RESOURCES + ["itemInfo.externalIds"]
      ).freeze

      # The bindings a "buy the book" link should point at. Legacy's
      # set_primary_amazon_url used exactly this list, deliberately excluding
      # ebook and audiobook.
      PHYSICAL_BINDINGS = %w[hardcover paperback mass_market].freeze

      def self.call(book:)
        new(book).call
      end

      def initialize(book)
        super
        @persisted = []
      end

      private

      alias_method :book, :record

      def validation_errors
        return ["Book title required"] if book.title.blank?
        return ["Book must have at least one author"] if book.authors.empty?
        []
      end

      def search_param_sets
        keywords = [book.title, book.authors.map(&:name).join(" ")].join(" ").squeeze(" ").strip

        [
          {keywords: keywords, search_index: "Books"},
          {keywords: keywords, search_index: "Books", browse_node_id: AUDIBLE_BROWSE_NODE}
        ]
      end

      def match_task_class
        ::Services::Ai::Tasks::Books::AmazonBookMatchTask
      end

      def persist_match(match, product)
        edition = ::Services::Books::AmazonEditionUpserter.call(book: book, product: product).edition
        @persisted << {edition: edition, product: product}

        link = upsert_external_link(parent: edition, product: product)
        attach_primary_image(
          parent: edition,
          image_url: product.dig("images", "primary", "large", "url")
        )
        link
      end

      def after_persist(_validated_results, _search_results)
        attach_book_cover
        attach_book_affiliate_link
      end

      # The cover comes from the best-selling physical edition THAT HAS ONE.
      # Ranking without that filter would let a coverless rank-winner leave the
      # book with no cover at all, when a lower-ranked physical edition has one.
      def attach_book_cover
        entry = best_physical { |candidate| image_url_for(candidate[:product]).present? }
        return if entry.nil?

        attach_primary_image(parent: book, image_url: image_url_for(entry[:product]))
      end

      # Legacy's set_primary_amazon_url: the book-level affiliate link points at
      # the best-selling physical edition, image or not.
      def attach_book_affiliate_link
        return if book.external_links.exists?(source: :amazon)

        entry = best_physical
        return if entry.nil?

        upsert_external_link(parent: book, product: entry[:product])
      end

      def best_physical
        candidates = @persisted.select { |entry| PHYSICAL_BINDINGS.include?(entry[:edition].book_binding) }
        candidates = candidates.select { |entry| yield(entry) } if block_given?
        candidates.min_by { |entry| entry[:edition].popularity || Float::INFINITY }
      end
    end
  end
end

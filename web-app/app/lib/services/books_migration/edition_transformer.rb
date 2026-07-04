module Services
  module BooksMigration
    # Legacy `editions` row -> new Books::Edition attributes. PURE (String-keyed
    # hash in -> symbol-keyed attrs out, no DB). `book_id` (direct passthrough)
    # and `language_id` (no legacy source) are handled by the migrator. `edition_type`
    # is omitted so the model default (:standard) applies. `book_binding` is re-encoded
    # to the NEW enum BY SYMBOL (never by int) — the old and new enums assign different
    # integers to the same names. `publisher_name` is pulled from the legacy Amazon
    # PA-API metadata (ByLineInfo.Manufacturer); the full metadata blob is still copied.
    class EditionTransformer
      # legacy book_binding int -> legacy symbol
      LEGACY_BINDING = {
        0 => :paperback, 1 => :hardcover, 2 => :ebook, 3 => :audible,
        4 => :mass_market_paperback, 5 => :audio, 6 => :library_binding,
        7 => :collectable, 8 => :leather_bound, 9 => :other
      }.freeze

      # legacy symbol -> new Books::Edition book_binding symbol
      BINDING_TO_NEW = {
        paperback: :paperback, hardcover: :hardcover, ebook: :ebook,
        audible: :audiobook, mass_market_paperback: :mass_market, audio: :audiobook,
        library_binding: :library_binding, collectable: :other,
        leather_bound: :leather_bound, other: :other
      }.freeze

      PUBLISHER_PATH = ["amazon", "ItemInfo", "ByLineInfo", "Manufacturer", "DisplayValue"].freeze

      def self.call(attrs)
        {
          title: attrs["title"],
          publication_year: attrs["publication_year"],
          popularity: attrs["popularity"],
          book_binding: book_binding(attrs["book_binding"]),
          publisher_name: publisher_name(attrs["metadata"]),
          metadata: attrs["metadata"] || {}
        }
      end

      def self.book_binding(legacy_int)
        return nil if legacy_int.nil?
        legacy_sym = LEGACY_BINDING.fetch(legacy_int) do
          raise "unknown legacy book_binding: #{legacy_int.inspect}"
        end
        BINDING_TO_NEW.fetch(legacy_sym)
      end
      private_class_method :book_binding

      def self.publisher_name(metadata)
        return nil unless metadata.is_a?(Hash)
        PUBLISHER_PATH.reduce(metadata) { |node, key| node.is_a?(Hash) ? node[key] : nil }.presence
      end
      private_class_method :publisher_name
    end
  end
end

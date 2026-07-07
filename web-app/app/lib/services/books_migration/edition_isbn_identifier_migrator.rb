module Services
  module BooksMigration
    # Legacy editions.identifiers (jsonb) -> work-level ISBN-family Identifiers on
    # the parent Books::Book. Editions are only READ here; each edition's ISBNs are
    # folded up to its book (edition.book_id is preserved = the Books::Book id).
    # jsonb keys isbn_10/isbn_13/ean are arrays (one identifier per element); asin
    # is a single string reclassified by shape. Values dedupe on the identifier
    # natural key, so overlap with book_identifiers collapses to one row.
    class EditionIsbnIdentifierMigrator < IdentifierMigrator
      ARRAY_KEYS = {
        "isbn_10" => :books_work_isbn10,
        "isbn_13" => :books_work_isbn13,
        "ean" => :books_work_ean13
      }.freeze

      private

      def legacy_model
        LegacyBooks::Edition
      end

      def model_key
        "Identifier (edition ISBN)"
      end

      def upsert_row(attrs)
        ids = attrs["identifiers"]
        return unless ids.is_a?(Hash)
        book_id = attrs["book_id"]

        ARRAY_KEYS.each do |key, identifier_type|
          Array(ids[key]).each do |value|
            upsert_identifier(
              identifiable_type: "Books::Book",
              identifiable_id: book_id,
              identifier_type: identifier_type,
              value: value.to_s.strip
            )
          end
        end

        Array(ids["asin"]).each do |value|
          stripped = value.to_s.strip
          upsert_identifier(
            identifiable_type: "Books::Book",
            identifiable_id: book_id,
            identifier_type: self.class.asin_identifier_type(stripped),
            value: stripped
          )
        end
      end
    end
  end
end

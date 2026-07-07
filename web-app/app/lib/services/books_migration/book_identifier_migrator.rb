module Services
  module BooksMigration
    # Legacy book_identifiers -> work-level Identifiers on Books::Book. book_id is
    # preserved, so it is the new Books::Book id directly. Handles the whole legacy
    # ISBN family plus goodreads:
    #   1 isbn10, 2 isbn13, 4 ean13, 5 goodreads -> fixed types;
    #   3 asin    -> isbn10 if ISBN-10-shaped, else asin (see asin_identifier_type).
    # Values dedupe on the identifier natural key (find_or_create_by!), so a value
    # also present in editions.identifiers collapses to one row.
    class BookIdentifierMigrator < IdentifierMigrator
      TYPE_MAP = {
        1 => :books_work_isbn10,
        2 => :books_work_isbn13,
        4 => :books_work_ean13,
        5 => :books_work_goodreads_id
      }.freeze
      ASIN_TYPE = 3

      private

      def legacy_model
        LegacyBooks::BookIdentifier
      end

      def model_key
        "Identifier (book_identifiers)"
      end

      def upsert_row(attrs)
        value = attrs["identifier"]
        legacy_type = attrs["identifier_type"]
        identifier_type =
          (legacy_type == ASIN_TYPE) ? self.class.asin_identifier_type(value) : TYPE_MAP[legacy_type]
        return if identifier_type.nil?
        upsert_identifier(
          identifiable_type: "Books::Book",
          identifiable_id: attrs["book_id"],
          identifier_type: identifier_type,
          value: value
        )
      end
    end
  end
end

module Services
  module BooksMigration
    # Legacy book_identifiers -> Identifier on Books::Book. This pass migrates only
    # the goodreads type (legacy identifier_type == 5) as books_work_goodreads_id;
    # the edition-level ISBN/ASIN/EAN types (1..4) are deferred to a later pass.
    # book_id is preserved, so it is the new Books::Book id directly.
    class BookIdentifierMigrator < IdentifierMigrator
      GOODREADS_TYPE = 5

      private

      def legacy_model
        LegacyBooks::BookIdentifier
      end

      def model_key
        "Identifier (book goodreads)"
      end

      def upsert_row(attrs)
        return unless attrs["identifier_type"] == GOODREADS_TYPE
        upsert_identifier(
          identifiable_type: "Books::Book",
          identifiable_id: attrs["book_id"],
          identifier_type: :books_work_goodreads_id,
          value: attrs["identifier"]
        )
      end
    end
  end
end

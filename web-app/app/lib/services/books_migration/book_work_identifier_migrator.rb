module Services
  module BooksMigration
    # Legacy books table -> work-level Identifiers on Books::Book. ol_work_id (OL
    # key stripped) -> books_work_openlibrary_id; goodreads_id (verbatim) ->
    # books_work_goodreads_id. book id is preserved. A book yields 0-2 identifiers;
    # upsert_identifier skips the ones whose source column is blank.
    class BookWorkIdentifierMigrator < IdentifierMigrator
      private

      def legacy_model
        LegacyBooks::Book
      end

      def model_key
        "Identifier (book work-level)"
      end

      def upsert_row(attrs)
        upsert_identifier(
          identifiable_type: "Books::Book", identifiable_id: attrs["id"],
          identifier_type: :books_work_openlibrary_id,
          value: self.class.strip_openlibrary_key(attrs["ol_work_id"])
        )
        upsert_identifier(
          identifiable_type: "Books::Book", identifiable_id: attrs["id"],
          identifier_type: :books_work_goodreads_id,
          value: attrs["goodreads_id"]
        )
      end
    end
  end
end

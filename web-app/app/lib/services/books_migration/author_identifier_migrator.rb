module Services
  module BooksMigration
    # Legacy authors table -> Books::Author books_author_openlibrary_id (OL key
    # stripped). author id is preserved.
    class AuthorIdentifierMigrator < IdentifierMigrator
      private

      def legacy_model
        LegacyBooks::Author
      end

      def model_key
        "Identifier (author openlibrary)"
      end

      def upsert_row(attrs)
        upsert_identifier(
          identifiable_type: "Books::Author", identifiable_id: attrs["id"],
          identifier_type: :books_author_openlibrary_id,
          value: self.class.strip_openlibrary_key(attrs["ol_author_id"])
        )
      end
    end
  end
end

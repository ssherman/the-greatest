module Services
  module BooksMigration
    # Legacy editions.ol_edition_id -> Books::Edition books_edition_openlibrary_id
    # (OL key stripped). Editions have FRESH ids, so the legacy edition id is
    # remapped to the new id through LegacyIdMap (editions migrate first). Rows with
    # no ol_edition_id, or with no map entry, are skipped (upsert_identifier's nil
    # guard handles a nil new id).
    class EditionIdentifierMigrator < IdentifierMigrator
      private

      def legacy_model
        LegacyBooks::Edition
      end

      def model_key
        "Identifier (edition openlibrary)"
      end

      def upsert_row(attrs)
        value = self.class.strip_openlibrary_key(attrs["ol_edition_id"])
        return if value.nil?
        upsert_identifier(
          identifiable_type: "Books::Edition",
          identifiable_id: LegacyIdMap.lookup(model: "Books::Edition", legacy_id: attrs["id"]),
          identifier_type: :books_edition_openlibrary_id,
          value: value
        )
      end
    end
  end
end

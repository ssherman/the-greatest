module Services
  module BooksMigration
    # Preserved-id migrator: books_books is a books-only table, so legacy book ids
    # are kept verbatim (book URLs). Writes through Books::Book (FriendlyId slug,
    # title normalization, book_kind default). Remaps original_language_id through
    # LegacyIdMap (languages migrate first) — the first real consumer of the map.
    # Resets the PK sequence after load.
    class BookMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Book
      end

      def model_key
        "Books::Book"
      end

      def upsert_row(attrs)
        book = Books::Book.find_or_initialize_by(id: attrs["id"])
        book.assign_attributes(BookTransformer.call(attrs))
        book.original_language_id = remap_language(attrs["original_language_id"])
        book.save!
      end

      def remap_language(legacy_language_id)
        return nil if legacy_language_id.nil?
        LegacyIdMap.lookup(model: "Language", legacy_id: legacy_language_id)
      end

      def finalize
        Books::Book.connection.reset_pk_sequence!("books_books")
      end
    end
  end
end

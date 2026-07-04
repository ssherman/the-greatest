module Services
  module BooksMigration
    # Preserved-id migrator: books_authors is a books-only table, so legacy author
    # ids are kept verbatim (author URLs). Writes through Books::Author so
    # FriendlyId slugs, name normalization, and the kind enum all apply. Resets
    # the PK sequence after load so later auto-inserts don't collide.
    class AuthorMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Author
      end

      def model_key
        "Books::Author"
      end

      def upsert_row(attrs)
        author = Books::Author.find_or_initialize_by(id: attrs["id"])
        author.assign_attributes(AuthorTransformer.call(attrs))
        author.save!
      end

      def finalize
        Books::Author.connection.reset_pk_sequence!("books_authors")
      end
    end
  end
end

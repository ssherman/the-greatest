module Services
  module BooksMigration
    # Preserved-id migrator: books_authors is a books-only table, so legacy author
    # ids are kept verbatim (author URLs). Writes through Books::Author so
    # FriendlyId slugs, name normalization, and the kind enum all apply. Moves the
    # PK sequence to the reserved ceiling after load so later auto-inserts never
    # take an id legacy will hand out.
    class AuthorMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Author
      end

      def model_key
        "Books::Author"
      end

      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("books_authors", attrs["id"])
        # Insert-only in sync mode: the catalog here is the master (spec §5).
        return if sync && ::Books::Author.exists?(attrs["id"])

        author = ::Books::Author.find_or_initialize_by(id: attrs["id"])
        author.assign_attributes(AuthorTransformer.call(attrs))
        author.save!
      end

      def sync_filter
        [:author_ids, "id"]
      end

      def finalize
        Services::BooksMigration.bump_sequence_to_floor!("books_authors")
      end
    end
  end
end

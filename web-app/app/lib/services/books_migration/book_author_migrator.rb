module Services
  module BooksMigration
    # Join-table migrator: legacy book_authors -> books_book_authors. Both
    # book_id and author_id are preserved ids (books/authors migrate first), so
    # they map straight through. Idempotent on the [book_id, author_id] natural
    # key. Not URL-facing, so ids are fresh (no sequence reset needed).
    class BookAuthorMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::BookAuthor
      end

      def model_key
        "Books::BookAuthor"
      end

      def upsert_row(attrs)
        book_author = Books::BookAuthor.find_or_initialize_by(
          book_id: attrs["book_id"], author_id: attrs["author_id"]
        )
        book_author.assign_attributes(BookAuthorTransformer.call(attrs))
        book_author.save!
      end
    end
  end
end

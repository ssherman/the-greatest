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
        author_id = attrs["author_id"]
        if sync
          # A new book may name an author that was merged or deleted here (spec §5).
          author_id = sync.redirects.resolve("Books::Author", author_id)
          if author_id == :deleted
            @dropped_deleted = @dropped_deleted.to_i + 1
            return
          end
        end

        book_author = ::Books::BookAuthor.find_or_initialize_by(book_id: attrs["book_id"], author_id: author_id)
        return if sync && book_author.persisted?

        book_author.assign_attributes(BookAuthorTransformer.call(attrs))
        book_author.save!
      end

      def sync_filter
        [:book_ids, "book_id"]
      end

      def extra_result_data
        sync ? {dropped_deleted: @dropped_deleted.to_i} : {}
      end
    end
  end
end

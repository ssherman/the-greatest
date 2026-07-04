module Services
  module BooksMigration
    # Fresh-id migrator: legacy editions -> books_editions. Editions aren't
    # URL-facing, so they take new auto ids; the LegacyIdMap ("Books::Edition")
    # is the dedup key (editions have no natural business key) and is needed by
    # the later identifiers pass. book_id is a direct passthrough (books preserve
    # their id). finalize back-references default_edition_id onto books_books.
    class EditionMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Edition
      end

      def model_key
        "Books::Edition"
      end

      def upsert_row(attrs)
        Books::Edition.transaction do
          new_id = LegacyIdMap.lookup(model: model_key, legacy_id: attrs["id"])
          edition = new_id ? Books::Edition.find(new_id) : Books::Edition.new
          edition.assign_attributes(EditionTransformer.call(attrs))
          edition.book_id = attrs["book_id"]
          edition.save!
          LegacyIdMap.record(model: model_key, legacy_id: attrs["id"], new_id: edition.id)
        end
      end

      # Set each book's default_edition_id to its most-popular edition (popularity
      # desc, nulls last, id asc), for books that have editions only. Set-based SQL
      # bypasses AR callbacks (no SearchIndexRequest flood — finalize runs OUTSIDE
      # the without_search_indexing block) and is idempotent. Editionless books
      # keep default_edition_id NULL (no synthesis). Authoritative: recomputes on
      # every run (meant for a pre-launch cutover), so re-running tracks the
      # current most-popular edition rather than preserving a hand-picked default.
      def finalize
        Books::Book.connection.execute(<<~SQL)
          UPDATE books_books b
          SET default_edition_id = e.id
          FROM (
            SELECT DISTINCT ON (book_id) id, book_id
            FROM books_editions
            ORDER BY book_id, popularity DESC NULLS LAST, id ASC
          ) e
          WHERE e.book_id = b.id
        SQL
      end
    end
  end
end

module Services
  module BooksMigration
    # Bulk join migrator: legacy book_countries -> books_book_countries. Both sides
    # already preserve their ids (books via BookMigrator, countries via
    # CountryMigrator), so there is no remapping at all and build_rows is a straight
    # field copy — the simplest migrator in the suite. A book_id or country_id with
    # no migrated row fails loud through the DB foreign key rather than dropping
    # silently to a success-looking low count, matching ExternalLinkMigrator.
    # finalize recomputes books_countries.book_count, which upsert_all bypasses
    # (counter_cache is a callback); it runs OUTSIDE without_search_indexing, so it
    # must stay raw SQL. flush is overridden to wrap the inherited upsert_all in a
    # transaction: BulkUpsertMigrator#flush otherwise calls it bare, which is fine in
    # production (each flush is already one atomic statement) but a real FK violation
    # here poisons Rails' ambient test transaction and breaks any DB assertion later in
    # the same test — this is the first BulkUpsertMigrator subclass whose fail-loud path
    # is a genuine DB constraint rather than a Ruby-level raise, so the first to hit it.
    class BookCountryMigrator < BulkUpsertMigrator
      private

      def legacy_model
        LegacyBooks::BookCountry
      end

      def model_key
        "Books::BookCountry"
      end

      def target_model
        Books::BookCountry
      end

      def unique_by
        :index_books_book_countries_on_book_id_and_country_id
      end

      def build_rows(attrs)
        [{book_id: attrs["book_id"], country_id: attrs["country_id"]}]
      end

      def flush(rows)
        target_model.transaction { super }
      end

      def finalize
        Books::BookCountry.connection.execute(<<~SQL)
          UPDATE books_countries c
          SET book_count = (
            SELECT COUNT(*) FROM books_book_countries bc WHERE bc.country_id = c.id
          )
        SQL
      end
    end
  end
end

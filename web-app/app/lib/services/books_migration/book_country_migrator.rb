module Services
  module BooksMigration
    # Bulk join migrator: legacy book_countries -> books_book_countries. Both sides
    # already preserve their ids (books via BookMigrator, countries via
    # CountryMigrator), so there is no LegacyIdMap to consult for either side.
    # country_id is checked in Ruby against the full set of current
    # books_countries ids, preloaded once in preload_context: an unmigrated
    # country_id raises before any DB write, naming the legacy id, so a
    # 126,007-row production run fails with a precise message instead of a
    # generic PG constraint error. book_id is passed straight through unchecked
    # (mirrors CategoryItemMigrator's treatment of its own item_id), so an
    # unmigrated book_id still fails loud through the DB foreign key on flush.
    # finalize recomputes books_countries.book_count, which upsert_all bypasses
    # (counter_cache is a callback); it runs OUTSIDE without_search_indexing, so it
    # must stay raw SQL.
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

      def preload_context
        @country_ids = Books::Country.pluck(:id).to_set
      end

      def build_rows(attrs)
        country_id = attrs["country_id"]
        unless @country_ids.include?(country_id)
          raise "no migrated Books::Country for legacy book_countries.country_id=#{country_id} (run the countries migrator first)"
        end
        [{book_id: attrs["book_id"], country_id: country_id}]
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

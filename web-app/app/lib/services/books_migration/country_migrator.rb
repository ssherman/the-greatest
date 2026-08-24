module Services
  module BooksMigration
    # Preserved-id migrator: books_countries is a brand-new books-only table that
    # nothing else writes to, so legacy country ids are kept verbatim and no
    # LegacyIdMap entry is needed — BookCountryMigrator joins on them directly.
    # The slug is pinned per-instance because FriendlyId would otherwise regenerate
    # it from name on insert, and /written-by/:slug/authors is an indexed URL.
    # labels is NOT NULL default [], so a nil legacy labels becomes []. book_count
    # is left at 0 here and recomputed by BookCountryMigrator#finalize, once the
    # links it counts actually exist. Resets the PK sequence after load so later
    # auto-inserts don't collide.
    class CountryMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Country
      end

      def model_key
        "Books::Country"
      end

      def upsert_row(attrs)
        country = ::Books::Country.find_or_initialize_by(id: attrs["id"])
        country.assign_attributes(
          name: attrs["name"],
          slug: attrs["slug"],
          description: attrs["description"],
          labels: Array(attrs["labels"])
        )
        def country.should_generate_new_friendly_id? = false
        country.save!
      end

      def finalize
        ::Books::Country.connection.reset_pk_sequence!("books_countries")
      end
    end
  end
end

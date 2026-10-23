module Services
  module BooksMigration
    # Preserved-id migrator: books_books is a books-only table, so legacy book ids
    # are kept verbatim (book URLs). Writes through Books::Book (FriendlyId slug,
    # title normalization, book_kind default). Remaps original_language_id through
    # LegacyIdMap (languages migrate first) — the first real consumer of the map.
    # Moves the PK sequence to the reserved ceiling after load
    # (Services::BooksMigration::RESERVED_CEILINGS).
    class BookMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Book
      end

      def model_key
        "Books::Book"
      end

      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("books_books", attrs["id"])
        # Insert-only in sync mode: the catalog here is the master (spec §5).
        return if sync && ::Books::Book.exists?(attrs["id"])

        # One transaction: a saved book without its titles would be skipped by
        # every later sync (insert-only), losing them for good.
        ::Books::Book.transaction do
          book = ::Books::Book.find_or_initialize_by(id: attrs["id"])
          attributes = BookTransformer.call(attrs)
          alternate_titles = attributes.delete(:alternate_titles)
          book.assign_attributes(attributes)
          book.original_language_id = remap_language(attrs["original_language_id"])
          book.save!
          # Rows are the truth; a title an editor removed stays removed on a re-run.
          ::Services::AlternateTitles::Writer.add(record: book, titles: alternate_titles, source: :legacy)
          book.save! if book.changed?
        end
      end

      def sync_filter
        [:book_ids, "id"]
      end

      # A genuinely nil legacy language maps to nil. But a NON-nil legacy id with
      # no map means a missing prerequisite (languages not migrated yet, or a
      # partial/failed language run) — raise so the per-row error names the book's
      # legacy id and the run can be corrected and re-run, rather than silently
      # dropping the language onto the optional FK.
      def remap_language(legacy_language_id)
        return nil if legacy_language_id.nil?
        LegacyIdMap.lookup(model: "Language", legacy_id: legacy_language_id) ||
          raise("no LegacyIdMap for Language legacy_id=#{legacy_language_id} (run the languages migrator first)")
      end

      def finalize
        Services::BooksMigration.bump_sequence_to_floor!("books_books")
      end
    end
  end
end

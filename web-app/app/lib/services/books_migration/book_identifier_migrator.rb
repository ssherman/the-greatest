module Services
  module BooksMigration
    # Legacy book_identifiers -> work-level Identifiers on Books::Book. book_id is
    # preserved, so it is the new Books::Book id directly. Handles the whole legacy
    # ISBN family plus goodreads:
    #   1 isbn10, 2 isbn13, 4 ean13, 5 goodreads -> fixed types;
    #   3 asin    -> isbn10 if ISBN-10-shaped, else asin (see asin_identifier_type).
    # Values dedupe on the identifier natural key (find_or_create_by!), so a value
    # also present in editions.identifiers collapses to one row.
    class BookIdentifierMigrator < IdentifierMigrator
      TYPE_MAP = {
        1 => :books_work_isbn10,
        2 => :books_work_isbn13,
        4 => :books_work_ean13,
        5 => :books_work_goodreads_id
      }.freeze
      ASIN_TYPE = 3

      private

      def legacy_model
        LegacyBooks::BookIdentifier
      end

      def model_key
        "Identifier (book_identifiers)"
      end

      def upsert_row(attrs)
        value = attrs["identifier"]
        legacy_type = attrs["identifier_type"]
        identifier_type =
          (legacy_type == ASIN_TYPE) ? self.class.asin_identifier_type(value) : TYPE_MAP[legacy_type]
        return if identifier_type.nil?

        book_id = attrs["book_id"]
        if sync
          book_id = sync.redirects.resolve("Books::Book", book_id)
          if book_id == :deleted
            @dropped_deleted = @dropped_deleted.to_i + 1
            return
          end
        end

        upsert_identifier(
          identifiable_type: "Books::Book",
          identifiable_id: book_id,
          identifier_type: identifier_type,
          value: value
        )
      end

      # The run's new book_identifiers rows on any book, plus every row of the run's
      # new books: one created between the final :all and sync_init sits below the
      # identifier watermark (spec §5; find_or_create makes the overlap harmless).
      def in_sync_scope?(attrs)
        return true unless sync

        sync.identifier_ids.include?(attrs["id"]) || sync.book_ids.include?(attrs["book_id"])
      end

      def legacy_each(&block)
        relation = legacy_model
        if sync
          relation = legacy_model.where(id: sync.identifier_ids.to_a).or(legacy_model.where(book_id: sync.book_ids.to_a))
        end
        relation.find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def extra_result_data
        sync ? {dropped_deleted: @dropped_deleted.to_i} : {}
      end
    end
  end
end

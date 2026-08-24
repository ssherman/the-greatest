module Services
  module BooksMigration
    # Legacy `books` description columns -> polymorphic Description rows (describable =
    # Books::Book, which preserves its legacy id, so no LegacyIdMap lookup is needed).
    #
    # Reads all THREE legacy columns and never books_books.description: that column already
    # IS the legacy raw description, ported by BookMigrator, so reading it too would
    # double-create. Fixing the original porting gap is the point of this migrator --
    # BookTransformer took the raw column, while the legacy site displays
    # description_to_display, which resolves to ai_generated_description for 87.5% of books.
    #
    # insert_all rather than upsert_all comes from InsertOnlyMigrator; see its header for why.
    #
    # No intra-batch dedup set is needed. Each legacy book yields at most one row per source
    # value: :ai_generated, :goodreads, and one normalised source that is never either of
    # those (DescriptionSourceNormalizer never returns them -- a raw description labelled
    # "Goodreads" becomes :other).
    #
    # rank: :preferred goes only where a human chose (D11). use_description = default is
    # reproduced exactly by SourcePriority::ORDER, so only the explicit choices are marked,
    # and only when the chosen column actually holds text: 658 of the 2,137 legacy
    # use_goodreads books have no goodreads_description, and legacy description_to_display
    # falls through to the AI text for them.
    class BookDescriptionMigrator < InsertOnlyMigrator
      USE_GOODREADS = 1
      USE_DESCRIPTION = 2

      LEGACY_COLUMNS = %i[
        id
        ai_generated_description
        goodreads_description
        description
        description_source_name
        description_source_url
        use_description
      ].freeze

      private

      def legacy_model
        LegacyBooks::Book
      end

      def model_key
        "Books::Book Description"
      end

      def target_model
        Description
      end

      def unique_by
        :index_descriptions_on_describable_and_key
      end

      def preload_context
        @book_ids = ::Books::Book.pluck(:id).to_set
      end

      # Narrowed to the columns actually mapped -- the legacy books table is wide, and the
      # base implementation would load every column of all 126,204 rows.
      def legacy_each(&block)
        legacy_model.select(*LEGACY_COLUMNS).find_each(batch_size: BATCH_SIZE) do |record|
          block.call(record.attributes)
        end
      end

      def build_rows(attrs)
        book_id = attrs["id"]
        unless @book_ids.include?(book_id)
          raise "no migrated Books::Book for legacy books.id=#{book_id.inspect}"
        end

        use = attrs["use_description"]
        rows = []

        if (content = attrs["ai_generated_description"].presence)
          rows << row(book_id, content, source: :ai_generated)
        end

        if (content = attrs["goodreads_description"].presence)
          rows << row(book_id, content,
            source: :goodreads,
            license: :proprietary,
            rank: (use == USE_GOODREADS) ? :preferred : :normal)
        end

        if (content = attrs["description"].presence)
          mapped = DescriptionSourceNormalizer.call(attrs["description_source_name"])
          rows << row(book_id, content,
            source: mapped[:source],
            source_name: mapped[:source_name],
            license: mapped[:license],
            source_url: attrs["description_source_url"].presence,
            rank: (use == USE_DESCRIPTION) ? :preferred : :normal)
        end

        rows
      end

      def row(book_id, content, source:, source_name: nil, license: nil, source_url: nil, rank: :normal)
        {
          describable_type: "Books::Book",
          describable_id: book_id,
          kind: :summary,
          locale: "en",
          source: source,
          source_name: source_name,
          content: content,
          rank: rank,
          source_url: source_url,
          license: license
        }
      end
    end
  end
end

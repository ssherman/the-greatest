module Services
  module BooksMigration
    # Legacy `authors` description columns -> polymorphic Description rows (describable =
    # Books::Author, which preserves its legacy id).
    #
    # ai_description (38,114 rows) was never ported at all -- AuthorTransformer had the same
    # gap as BookTransformer, while the legacy author page renders
    # `ai_description || description`. That fallback is reproduced by SourcePriority::ORDER
    # putting :ai_generated ahead of :wikipedia and :other, so this migrator creates no
    # preferred rows.
    #
    # Reads only the legacy columns, never books_authors.description -- that column already
    # IS the legacy raw description, so reading it too would double-create. The legacy
    # column here is `description_source`, singular: the authors table names it differently
    # to books.
    #
    # Provenance is not blanket-Wikipedia. 8,218 of the 8,670 legacy author descriptions
    # state description_source = wikipedia with an en.wikipedia.org URL; the remaining 452
    # state no source and carry no URL. DescriptionSourceNormalizer sends those to
    # :other + "Unattributed" with no licence, the same rule the books migrator applies to
    # its 659 unsourced rows -- asserting cc_by_sa_4 on text with nothing to attribute to
    # would be a claim increment (d)'s AttributionComponent could not honour (D10).
    #
    # insert_all rather than upsert_all comes from InsertOnlyMigrator; see its header for
    # why. No intra-batch dedup set is needed: each legacy author yields at most one row per
    # source value, and the normaliser never returns :ai_generated.
    class AuthorDescriptionMigrator < InsertOnlyMigrator
      LEGACY_COLUMNS = %i[
        id
        ai_description
        description
        description_source
        description_source_url
      ].freeze

      private

      def legacy_model
        LegacyBooks::Author
      end

      def model_key
        "Books::Author Description"
      end

      def target_model
        Description
      end

      def unique_by
        :index_descriptions_on_describable_and_key
      end

      def preload_context
        @author_ids = Books::Author.pluck(:id).to_set
      end

      def legacy_each(&block)
        legacy_model.select(*LEGACY_COLUMNS).find_each(batch_size: BATCH_SIZE) do |record|
          block.call(record.attributes)
        end
      end

      def build_rows(attrs)
        author_id = attrs["id"]
        unless @author_ids.include?(author_id)
          raise "no migrated Books::Author for legacy authors.id=#{author_id.inspect}"
        end

        rows = []

        if (content = attrs["ai_description"].presence)
          rows << row(author_id, content, source: :ai_generated)
        end

        if (content = attrs["description"].presence)
          mapped = DescriptionSourceNormalizer.call(attrs["description_source"])
          rows << row(author_id, content,
            source: mapped[:source],
            source_name: mapped[:source_name],
            license: mapped[:license],
            source_url: attrs["description_source_url"].presence)
        end

        rows
      end

      def row(author_id, content, source:, source_name: nil, license: nil, source_url: nil)
        {
          describable_type: "Books::Author",
          describable_id: author_id,
          kind: :summary,
          locale: "en",
          source: source,
          source_name: source_name,
          content: content,
          rank: :normal,
          source_url: source_url,
          license: license
        }
      end
    end
  end
end

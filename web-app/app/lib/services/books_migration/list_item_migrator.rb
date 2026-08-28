module Services
  module BooksMigration
    # Legacy `list_items` -> polymorphic list_items (listable = Books::Book), fresh id.
    # Bulk upsert on the natural-key unique index [list_id, listable_type, listable_id].
    # Every legacy row has a non-null book_id (no pending items), so there are no
    # NULL-in-unique-index rows and (since [list_id, book_id] is unique in the source) no
    # intra-batch ON CONFLICT double-touch. listable has no DB FK (polymorphic), so a
    # book_id with no migrated Books::Book is a fail-loud raise naming the legacy
    # list_item id (preloaded id set). A list_id belonging to one of
    # ListMigrator::SUPERSEDED_LIST_NAMES is SKIPPED instead: ListMigrator deliberately
    # drops those three, and list_items.list_id DOES carry a foreign key, so importing
    # their ~7,000 items would abort the whole run rather than merely orphan them. Any
    # OTHER missing parent is still a fail-loud raise, and the "you forgot
    # data_migration:lists" ordering mistake is caught by the empty-set guard.
    # metadata <- pending_book_data parsed from either
    # JSON or YAML (legacy serialize drift) into a plain Hash (plain jsonb; a raw string
    # would store as a jsonb string scalar). verified defaults false. Legacy
    # created_at/updated_at preserved.
    class ListItemMigrator < BulkUpsertMigrator
      private

      def legacy_model
        LegacyBooks::ListItem
      end

      def model_key
        "ListItem"
      end

      def target_model
        ListItem
      end

      def unique_by
        :index_list_items_on_list_and_listable_unique
      end

      def record_timestamps?
        false
      end

      def preload_context
        @book_ids = ::Books::Book.pluck(:id).to_set
        @list_ids = ::Books::List.pluck(:id).to_set
        raise "no migrated Books::List; run data_migration:lists first" if @list_ids.empty?
        # Memoized once per run: three ids, one query.
        @superseded_list_ids = ListMigrator.superseded_legacy_list_ids
      end

      def build_rows(attrs)
        list_id = attrs["list_id"]
        unless @list_ids.include?(list_id)
          # ONLY the three superseded users' favorites lists are legitimately
          # absent. Skipping every missing parent would mask a ListMigrator that
          # died partway -- its committed batches leave @list_ids non-empty, so
          # the guard above cannot catch that.
          return [] if @superseded_list_ids.include?(list_id)

          raise "no migrated Books::List for legacy list_items.list_id=#{list_id.inspect} (list_item id=#{attrs["id"]})"
        end

        book_id = attrs["book_id"]
        unless @book_ids.include?(book_id)
          raise "no migrated Books::Book for legacy list_items.book_id=#{book_id.inspect} (list_item id=#{attrs["id"]})"
        end

        [{
          list_id: attrs["list_id"],
          listable_type: "Books::Book",
          listable_id: book_id,
          position: attrs["position"],
          metadata: parse_metadata(attrs["pending_book_data"]),
          verified: false,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      def parse_metadata(value)
        return nil if value.blank?
        str = value.strip
        parsed = if str.start_with?("---")
          YAML.safe_load(str, permitted_classes: [Symbol, ActiveSupport::HashWithIndifferentAccess], aliases: true)
        else
          JSON.parse(str)
        end
        parsed.to_h
      end
    end
  end
end

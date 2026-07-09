module Services
  module BooksMigration
    # Legacy `list_items` -> polymorphic list_items (listable = Books::Book), fresh id.
    # Bulk upsert on the natural-key unique index [list_id, listable_type, listable_id].
    # Every legacy row has a non-null book_id (no pending items), so there are no
    # NULL-in-unique-index rows and (since [list_id, book_id] is unique in the source) no
    # intra-batch ON CONFLICT double-touch. listable has no DB FK (polymorphic), so a
    # book_id with no migrated Books::Book is a fail-loud raise naming the legacy
    # list_item id (preloaded id set). metadata <- parsed pending_book_data (plain jsonb;
    # a raw string would store as a jsonb string scalar). verified defaults false. Legacy
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
        @book_ids = Books::Book.pluck(:id).to_set
      end

      def build_rows(attrs)
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
        JSON.parse(value)
      end
    end
  end
end

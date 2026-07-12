module Services
  module BooksMigration
    # Legacy `user_list_books` -> polymorphic user_list_items (listable = Books::Book), fresh id.
    # Bulk upsert on the natural-key unique index [user_list_id, listable_type, listable_id];
    # legacy already enforces UNIQUE [user_list_id, book_id], so no intra-batch ON CONFLICT
    # double-touch. listable has no DB FK (polymorphic), so a book_id with no migrated
    # Books::Book is a fail-loud raise naming the legacy user_list_books id.
    #
    # position: nullable in legacy (779 rows) and drifted (gaps, plus 689 duplicate
    # [list, position] pairs), but NOT NULL here and the app assumes a contiguous 1..N. NULLs
    # enter as NULL_POSITION_SENTINEL — int max, so it sorts last and cannot collide (legacy
    # MAX(position) is 12,411) — and finalize renumbers every Books row to 1..N. Ordering by
    # (position, id) is stable across runs, so a re-run (whose upsert resets positions to
    # their legacy values) converges on the identical result.
    #
    # completed_on <- read_date. Legacy created_at/updated_at preserved.
    class UserListItemMigrator < BulkUpsertMigrator
      NULL_POSITION_SENTINEL = 2_147_483_647
      UPSERT_BATCH = 5_000

      private

      def legacy_model
        LegacyBooks::UserListBook
      end

      def model_key
        "UserListItem"
      end

      def target_model
        ::UserListItem
      end

      def unique_by
        :index_user_list_items_on_list_and_listable_unique
      end

      def record_timestamps?
        false
      end

      def upsert_batch
        UPSERT_BATCH
      end

      def preload_context
        @book_ids = Books::Book.pluck(:id).to_set
      end

      def build_rows(attrs)
        book_id = attrs["book_id"]
        unless @book_ids.include?(book_id)
          raise "no migrated Books::Book for legacy user_list_books.book_id=#{book_id.inspect} (user_list_book id=#{attrs["id"]})"
        end

        [{
          user_list_id: attrs["user_list_id"],
          listable_type: "Books::Book",
          listable_id: book_id,
          position: attrs["position"] || NULL_POSITION_SENTINEL,
          completed_on: attrs["read_date"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      def finalize
        target_model.connection.execute(<<~SQL.squish)
          UPDATE user_list_items
          SET position = ranked.new_position
          FROM (
            SELECT uli.id,
                   ROW_NUMBER() OVER (
                     PARTITION BY uli.user_list_id
                     ORDER BY uli.position, uli.id
                   ) AS new_position
            FROM user_list_items uli
            JOIN user_lists ul ON ul.id = uli.user_list_id
            WHERE ul.type = 'Books::UserList'
          ) ranked
          WHERE user_list_items.id = ranked.id
            AND user_list_items.position <> ranked.new_position
        SQL
      end
    end
  end
end

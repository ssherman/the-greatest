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
    # MAX(position) is 12,411) — and finalize renumbers legacy-origin Books lists (below the
    # user_lists ceiling) to 1..N; new-app lists keep their own positions. Ordering by
    # (position, id) is stable across runs, so a re-run (whose upsert resets positions to
    # their legacy values) converges on the identical result.
    #
    # completed_on <- read_date. Legacy created_at/updated_at preserved.
    #
    # In data_migration:sync it works list by list instead (see call and UserListItemPlan).
    class UserListItemMigrator < BulkUpsertMigrator
      NULL_POSITION_SENTINEL = 2_147_483_647
      UPSERT_BATCH = 5_000
      LIST_BATCH = 1_000

      # Sync mode (spec §6) works list by list instead of streaming every legacy
      # item: each batch of legacy-origin lists is made to match legacy, which is
      # what lets it delete items legacy removed and collapse merge collisions.
      def call
        return super unless sync

        @count = 0
        @stats = {inserted: 0, deleted: 0, dropped: 0, waiting: 0, collisions: 0}
        route = BookRoute.new(sync)
        Services::BooksMigration.without_search_indexing do
          legacy_origin_list_ids.each_slice(LIST_BATCH) { |list_ids| sync_lists(list_ids, route) }
        end
        finalize
        {success: true, data: {model: model_key, count: @count}.merge(@stats)}
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count}}
      end

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
        @book_ids = ::Books::Book.pluck(:id).to_set
      end

      def build_rows(attrs)
        book_id = attrs["book_id"]
        unless @book_ids.include?(book_id)
          raise "no migrated Books::Book for legacy user_list_books.book_id=#{book_id.inspect} (user_list_book id=#{attrs["id"]})"
        end

        [item_row(attrs, attrs["user_list_id"], book_id)]
      end

      def item_row(attrs, list_id, book_id)
        {
          user_list_id: list_id,
          listable_type: "Books::Book",
          listable_id: book_id,
          position: attrs["position"] || NULL_POSITION_SENTINEL,
          completed_on: attrs["read_date"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }
      end

      # A merge that commits while this batch is planned shows up in route.lock,
      # which reloads the redirects; the batch is then planned again. Three tries
      # covers a merge chain landing mid-batch; more means something is wrong.
      def sync_lists(list_ids, route)
        legacy_rows = legacy_items_for(list_ids)
        plan = nil
        rows = nil
        written = 3.times.any? do
          here = ::UserListItem.where(user_list_id: list_ids).pluck(:id, :user_list_id, :listable_type, :listable_id)
          plan = UserListItemPlan.call(legacy_rows, here, route)
          if plan.missing.any?
            raise "legacy user_list_books #{plan.missing.first(10).join(", ")} name a book that is neither here " \
              "nor redirected (removed without callbacks)"
          end

          rows = plan.keep.map { |(list_id, book_id), attrs| item_row(attrs, list_id, book_id) }
          ::UserListItem.transaction do
            next false unless route.lock(plan.keep.keys.map(&:last))

            ::UserListItem.where(id: plan.stale_ids).delete_all if plan.stale_ids.any?
            rows.each_slice(UPSERT_BATCH) do |slice|
              target_model.upsert_all(slice, unique_by: unique_by, record_timestamps: false)
            end
            true
          end
        end
        raise "user lists #{list_ids.first}..#{list_ids.last}: books kept vanishing mid-run; re-run the sync" unless written

        @count += rows.size
        @stats[:inserted] += plan.inserted
        @stats[:deleted] += plan.stale_ids.size
        %i[dropped waiting collisions].each { |key| @stats[key] += plan.public_send(key) }
      end

      def legacy_origin_list_ids
        ::Books::UserList.where(id: ...RESERVED_CEILINGS.fetch("user_lists")).order(:id).pluck(:id)
      end

      # Stubbed in tests, so the legacy connection is never opened.
      def legacy_items_for(list_ids)
        LegacyBooks::UserListBook.where(user_list_id: list_ids).map(&:attributes)
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
              AND ul.id < #{RESERVED_CEILINGS.fetch("user_lists").to_i}
          ) ranked
          WHERE user_list_items.id = ranked.id
            AND user_list_items.position <> ranked.new_position
        SQL
      end
    end
  end
end

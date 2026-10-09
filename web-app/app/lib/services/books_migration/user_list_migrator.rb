module Services
  module BooksMigration
    # Legacy `user_lists` -> STI Books::UserList, preserving id. Preservation is safe
    # because `user_lists` is a reserved-ceiling table (RESERVED_CEILINGS = 1_000_000) and
    # the legacy MAX(id) is 604,880 — every new-app row already lives at >= 1_000_001. It is
    # also load-bearing: the /user_lists/:id compatibility alias resolves a list by its raw
    # primary key, so preserving the ids is what lets the legacy books URLs keep working once
    # books is wired into that alias (today it 404s regardless, since UserList.subclasses_for
    # returns [] for the books domain).
    #
    # list_type is symbol-remapped: legacy is [read, reading, want_to_read, favorite, custom]
    # but every new-app subclass puts a plural `favorites` at 0. view_mode's legacy default
    # member is NULL, not 0; it means "user never picked one", so it maps to the new site
    # default (grid_view), not to the integer 0 slot. `public` is nullable in legacy but
    # NOT NULL here.
    # greatest_books_list / best_ranked / date_read are dropped — dead legacy flags with no
    # new-schema home. Bulk upsert_all bypasses the UserList callbacks and validations.
    # Idempotent on id. In data_migration:sync it also deletes legacy-origin Books lists
    # that legacy no longer has (spec §6).
    class UserListMigrator < BulkUpsertMigrator
      LIST_TYPE_MAP = {3 => 0, 0 => 1, 1 => 2, 2 => 3, 4 => 4}.freeze
      VIEW_MODE_MAP = {nil => 2, 1 => 1, 2 => 2}.freeze

      private

      def legacy_model
        LegacyBooks::UserList
      end

      def model_key
        "Books::UserList"
      end

      def target_model
        ::UserList
      end

      def unique_by
        :id
      end

      def record_timestamps?
        false
      end

      # Sync mode (spec §6) remembers which lists legacy has, so finalize can
      # delete the legacy-origin ones it no longer has.
      def preload_context
        return unless sync

        @here_ids = legacy_origin_lists.pluck(:id).to_set
        @legacy_ids = Set.new
        @items_deleted = 0
      end

      def build_rows(attrs)
        @legacy_ids << attrs["id"] if sync
        [{
          id: attrs["id"],
          type: "Books::UserList",
          user_id: attrs["user_id"],
          name: attrs["name"],
          description: attrs["description"],
          list_type: remap_list_type(attrs["list_type"]),
          view_mode: remap_view_mode(attrs["view_mode"]),
          public: attrs["public"] || false,
          position: attrs["position"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      # Runs only after every legacy row was read and written, so a failed run
      # deletes nothing. Items go first: user_list_items has a plain foreign key.
      def finalize
        return unless sync

        @doomed_ids = (@here_ids - @legacy_ids).to_a.sort
        Services::BooksMigration.guard_deletion!("user_lists", @doomed_ids.size, @here_ids.size)
        @doomed_ids.each_slice(1_000) do |ids|
          ::UserList.transaction do
            @items_deleted += ::UserListItem.where(user_list_id: ids).delete_all
            ::UserList.where(id: ids).delete_all
          end
        end
      end

      def extra_result_data
        return {} unless sync

        {inserted: (@legacy_ids - @here_ids).size, deleted: @doomed_ids.size, items_deleted: @items_deleted}
      end

      # Books lists below the ceiling came from legacy. New-app lists sit above it,
      # and other domains' lists are never this migrator's.
      def legacy_origin_lists
        ::Books::UserList.where(id: ...RESERVED_CEILINGS.fetch("user_lists"))
      end

      def remap_list_type(old)
        LIST_TYPE_MAP.fetch(old) { raise "unmapped legacy user_lists.list_type=#{old.inspect}" }
      end

      def remap_view_mode(old)
        VIEW_MODE_MAP.fetch(old) { raise "unmapped legacy user_lists.view_mode=#{old.inspect}" }
      end
    end
  end
end

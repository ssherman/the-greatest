module Services
  module BooksMigration
    # Legacy `user_lists` -> STI Books::UserList, preserving id. Preservation is safe
    # because `user_lists` is a reserved-ceiling table (RESERVED_CEILINGS = 1_000_000) and
    # the legacy MAX(id) is 604,880 — every new-app row already lives at >= 1_000_001. It is
    # also load-bearing: the /user_lists/:id compatibility alias resolves a list by its raw
    # primary key, so the legacy books URLs only keep working if the ids survive.
    #
    # list_type is symbol-remapped: legacy is [read, reading, want_to_read, favorite, custom]
    # but every new-app subclass puts a plural `favorites` at 0. view_mode's legacy default
    # member is NULL, not 0. `public` is nullable in legacy but NOT NULL here.
    # greatest_books_list / best_ranked / date_read are dropped — dead legacy flags with no
    # new-schema home. Bulk upsert_all bypasses the UserList callbacks and validations.
    # Idempotent on id.
    class UserListMigrator < BulkUpsertMigrator
      LIST_TYPE_MAP = {3 => 0, 0 => 1, 1 => 2, 2 => 3, 4 => 4}.freeze
      VIEW_MODE_MAP = {nil => 0, 1 => 1, 2 => 2}.freeze

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

      def build_rows(attrs)
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

      def remap_list_type(old)
        LIST_TYPE_MAP.fetch(old) { raise "unmapped legacy user_lists.list_type=#{old.inspect}" }
      end

      def remap_view_mode(old)
        VIEW_MODE_MAP.fetch(old) { raise "unmapped legacy user_lists.view_mode=#{old.inspect}" }
      end
    end
  end
end

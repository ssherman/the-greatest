module Services
  module BooksMigration
    # Legacy `list_con_lists` -> list_penalties, STATIC-target list_cons only (ListPenalty
    # forbids dynamic penalties; dynamic-side + genre-static->dynamic-global rows drop).
    # list_id comes from ranked_lists (joined in legacy_each; lists preserve their id, so
    # it is the Books::List id directly) -> fail-loud if not a migrated Books::List.
    # penalty_id via the "Penalty" map. Deduped in-memory on [list_id, penalty_id] because
    # two ranked_lists can map the same penalty onto the same list and upsert_all cannot
    # touch a conflict key twice in one statement. Idempotent on the target unique index.
    class ListPenaltyMigrator < BulkUpsertMigrator
      private

      def legacy_model
        LegacyBooks::ListConList
      end

      def model_key
        "ListPenalty"
      end

      def target_model
        ListPenalty
      end

      def unique_by
        :index_list_penalties_on_list_and_penalty
      end

      def record_timestamps?
        false
      end

      def preload_context
        @penalty_map = LegacyIdMap.where(model: "Penalty").pluck(:legacy_id, :new_id).to_h
        raise "no migrated penalties; run data_migration:penalties first" if @penalty_map.empty?
        @static_penalty_ids = Penalty.static.pluck(:id).to_set
        @static_list_con_ids = @penalty_map.select { |_legacy_id, new_id| @static_penalty_ids.include?(new_id) }.keys
        @list_ids = Books::List.pluck(:id).to_set
        @seen = Set.new
      end

      def legacy_each(&block)
        LegacyBooks::ListConList
          .joins("JOIN ranked_lists ON ranked_lists.id = list_con_lists.ranked_list_id")
          .where(list_con_id: @static_list_con_ids)
          .select("list_con_lists.id, list_con_lists.list_con_id, list_con_lists.created_at, list_con_lists.updated_at, ranked_lists.list_id AS list_id")
          .find_each(batch_size: BATCH_SIZE) do |record|
            block.call(
              "id" => record.id,
              "list_con_id" => record.list_con_id,
              "list_id" => record.list_id,
              "created_at" => record.created_at,
              "updated_at" => record.updated_at
            )
          end
      end

      def build_rows(attrs)
        penalty_id = @penalty_map.fetch(attrs["list_con_id"])
        return [] unless @static_penalty_ids.include?(penalty_id) # dynamic-target rows drop (ListPenalty is static-only)

        list_id = attrs["list_id"]
        unless @list_ids.include?(list_id)
          raise "no migrated Books::List for legacy list_con_lists.list_id=#{list_id.inspect} (list_con_list id=#{attrs["id"]})"
        end

        key = [list_id, penalty_id]
        return [] if @seen.include?(key)
        @seen << key

        [{
          list_id: list_id,
          penalty_id: penalty_id,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end
    end
  end
end

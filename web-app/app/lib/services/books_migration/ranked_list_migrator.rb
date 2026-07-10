module Services
  module BooksMigration
    # Legacy `ranked_lists` (active ranking_configurations only) -> ranked_lists, fresh id,
    # bulk upsert on the natural-key unique index [list_id, ranking_configuration_id].
    # ranking_configuration_id is remapped through the RC LegacyIdMap; legacy_each is scoped
    # to the mapped (= active) legacy RC ids, so archived-RC ranked_lists are skipped and
    # every yielded row's rc maps. list_id has NO DB FK (only ranking_configuration_id does),
    # so a list_id with no migrated Books::List is a fail-loud raise naming the legacy
    # ranked_list id (preloaded id set). weight and legacy created_at/updated_at preserved.
    class RankedListMigrator < BulkUpsertMigrator
      private

      def legacy_model
        LegacyBooks::RankedList
      end

      def model_key
        "RankedList"
      end

      def target_model
        RankedList
      end

      def unique_by
        :index_ranked_lists_on_list_and_config_unique
      end

      def record_timestamps?
        false
      end

      def preload_context
        @rc_map = LegacyIdMap.where(model: "Books::RankingConfiguration").pluck(:legacy_id, :new_id).to_h
        raise "no migrated ranking_configurations; run data_migration:ranking_configurations first" if @rc_map.empty?
        @list_ids = Books::List.pluck(:id).to_set
      end

      # Active RCs only: only ranked_lists whose rc was migrated (mapped) are yielded.
      def legacy_each(&block)
        legacy_model.where(ranking_configuration_id: @rc_map.keys).find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def build_rows(attrs)
        rc_new_id = @rc_map[attrs["ranking_configuration_id"]]
        unless rc_new_id
          raise "no migrated ranking_configuration for legacy ranked_lists.ranking_configuration_id=#{attrs["ranking_configuration_id"].inspect} (ranked_list id=#{attrs["id"]})"
        end

        list_id = attrs["list_id"]
        unless @list_ids.include?(list_id)
          raise "no migrated Books::List for legacy ranked_lists.list_id=#{list_id.inspect} (ranked_list id=#{attrs["id"]})"
        end

        [{
          list_id: list_id,
          ranking_configuration_id: rc_new_id,
          weight: attrs["weight"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end
    end
  end
end

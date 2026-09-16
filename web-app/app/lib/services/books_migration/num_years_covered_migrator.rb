module Services
  module BooksMigration
    # Legacy year-span list_cons (the seven "List: only covers N years" statics) ->
    # Books::List#num_years_covered. Those statics resolve to the num_years_covered
    # dynamic global (PenaltyResolver::YEAR_SPAN_BUCKETS), so the per-list fact they
    # carried has to land on the list. Value = the reviewed override in
    # config/books_migration/num_years_covered.yml when present, else the legacy
    # bucket. One value per list; the highest legacy ranking_configuration_id wins a
    # conflict. Plain overwrite (update_all), so it is idempotent and a re-run
    # re-applies an edited file. Lists with no year-span row are never touched.
    # Scoped to active legacy configurations via the "Books::RankingConfiguration"
    # map, like every other penalty-side migrator. Rows are selected by legacy
    # list_con NAME rather than through the "Penalty" id map on purpose: on a
    # database migrated before the resolver learned YEAR_SPAN_BUCKETS that map
    # still points the seven names at the Books statics, and this migrator has to
    # work there too (PenaltyReconciler repairs the rest).
    class NumYearsCoveredMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::ListConList
      end

      def model_key
        "Books::List#num_years_covered"
      end

      def legacy_each(&block)
        rc_ids = active_rc_legacy_ids
        legacy_model
          .joins("JOIN ranked_lists ON ranked_lists.id = list_con_lists.ranked_list_id")
          .joins("JOIN list_cons ON list_cons.id = list_con_lists.list_con_id")
          .where("list_cons.name IN (?) AND list_cons.ranking_configuration_id IN (?)", PenaltyResolver::YEAR_SPAN_BUCKETS.keys, rc_ids)
          .select("list_con_lists.id, ranked_lists.list_id AS list_id, list_cons.name AS list_con_name, list_cons.ranking_configuration_id AS ranking_configuration_id")
          .find_each(batch_size: BATCH_SIZE) do |record|
            block.call(
              "id" => record.id,
              "list_id" => record.list_id,
              "list_con_name" => record.list_con_name,
              "ranking_configuration_id" => record.ranking_configuration_id
            )
          end
      end

      # Collects only; the writes happen once per list in finalize.
      def upsert_row(attrs)
        bucket = PenaltyResolver::YEAR_SPAN_BUCKETS.fetch(attrs["list_con_name"]) do
          raise "unknown year-span list_con name #{attrs["list_con_name"].inspect}"
        end
        rc_id = attrs["ranking_configuration_id"]
        current = best[attrs["list_id"]]
        best[attrs["list_id"]] = [rc_id, bucket] if current.nil? || rc_id > current.first
      end

      def finalize
        raise "no migrated Books::List; run data_migration:lists first" unless ::Books::List.exists?

        overrides = NumYearsCoveredFile.load
        present = ::Books::List.where(id: best.keys).pluck(:id).to_set
        superseded = ListMigrator.superseded_legacy_list_ids
        @lists_updated = 0
        @overrides_applied = 0

        best.each do |list_id, (_rc_id, bucket)|
          unless present.include?(list_id)
            next if superseded.include?(list_id)

            raise "no migrated Books::List for legacy list id=#{list_id}"
          end

          if overrides.key?(list_id)
            value = overrides.fetch(list_id)
            @overrides_applied += 1
          else
            value = bucket
          end
          ::Books::List.where(id: list_id).update_all(num_years_covered: value)
          @lists_updated += 1
        end

        @unknown_override_ids = (overrides.keys - ::Books::List.where(id: overrides.keys).pluck(:id)).sort
      end

      def extra_result_data
        {
          lists_updated: @lists_updated,
          overrides_applied: @overrides_applied,
          unknown_override_ids: @unknown_override_ids
        }
      end

      def best
        @best ||= {}
      end

      def active_rc_legacy_ids
        ids = LegacyIdMap.where(model: "Books::RankingConfiguration").pluck(:legacy_id)
        raise "no migrated ranking_configurations; run data_migration:ranking_configurations first" if ids.empty?
        ids
      end
    end
  end
end

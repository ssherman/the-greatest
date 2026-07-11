module Services
  module BooksMigration
    # Legacy `list_cons` (active RCs) -> penalty_applications. penalty_id via the
    # "Penalty" map, ranking_configuration_id via the "Books::RankingConfiguration" map,
    # value = list_con.points. Per-row find_or_initialize + value = MAX(existing, points)
    # gives both the [penalty, rc] collision rule (one legacy pair: RC52) and idempotency
    # without an upsert_all "affect row twice" hazard. Records no id map (join table).
    class PenaltyApplicationMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::ListCon
      end

      def model_key
        "PenaltyApplication"
      end

      def legacy_each(&block)
        legacy_model.where(ranking_configuration_id: rc_map.keys).find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def upsert_row(attrs)
        penalty_id = penalty_map.fetch(attrs["id"])
        rc_id = rc_map.fetch(attrs["ranking_configuration_id"])
        pa = PenaltyApplication.find_or_initialize_by(penalty_id: penalty_id, ranking_configuration_id: rc_id)
        pa.value = [pa.value || 0, attrs["points"]].max
        pa.created_at = attrs["created_at"] if pa.new_record?
        pa.updated_at = attrs["updated_at"]
        pa.save!
      end

      def penalty_map
        @penalty_map ||= begin
          map = LegacyIdMap.where(model: "Penalty").pluck(:legacy_id, :new_id).to_h
          raise "no migrated penalties; run data_migration:penalties first" if map.empty?
          map
        end
      end

      def rc_map
        @rc_map ||= begin
          map = LegacyIdMap.where(model: "Books::RankingConfiguration").pluck(:legacy_id, :new_id).to_h
          raise "no migrated ranking_configurations; run data_migration:ranking_configurations first" if map.empty?
          map
        end
      end
    end
  end
end

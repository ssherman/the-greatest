module Services
  module BooksMigration
    # Legacy `list_cons` (active RCs only) -> penalties, recording LegacyIdMap "Penalty"
    # (list_con.id -> penalty.id, many-to-one). PenaltyResolver decides reuse-global vs
    # create-Books; created Books::Penalty rows keep the legacy name/description/timestamps
    # (first-writer-wins via find_or_create_by across RCs). Scoped to whatever RCs 2b
    # migrated (the "Books::RankingConfiguration" map) — raises if that map is empty.
    class PenaltyMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::ListCon
      end

      def model_key
        "Penalty"
      end

      def legacy_each(&block)
        ids = active_rc_legacy_ids
        legacy_model.where(ranking_configuration_id: ids).find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def upsert_row(attrs)
        strategy, payload = resolver.call(attrs)
        penalty =
          case strategy
          when :reuse
            payload
          when :create_books
            Books::Penalty.find_or_create_by!(name: payload[:name], user_id: nil) do |p|
              p.dynamic_type = payload[:dynamic_type]
              p.description = attrs["description"]
              p.created_at = attrs["created_at"]
              p.updated_at = attrs["updated_at"]
            end
          end
        LegacyIdMap.record(model: model_key, legacy_id: attrs["id"], new_id: penalty.id)
      end

      def active_rc_legacy_ids
        @active_rc_legacy_ids ||= begin
          ids = LegacyIdMap.where(model: "Books::RankingConfiguration").pluck(:legacy_id)
          raise "no migrated ranking_configurations; run data_migration:ranking_configurations first" if ids.empty?
          ids
        end
      end

      def resolver
        @resolver ||= begin
          globals = Penalty.where(type: "Global::Penalty").to_a
          PenaltyResolver.new(
            globals_by_name: globals.index_by(&:name),
            globals_by_dynamic_type: globals.select(&:dynamic_type).index_by(&:dynamic_type)
          )
        end
      end
    end
  end
end

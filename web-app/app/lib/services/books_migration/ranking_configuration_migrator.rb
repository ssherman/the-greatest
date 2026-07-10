module Services
  module BooksMigration
    # Fresh-id migrator: active (archived=false) legacy ranking_configurations -> STI
    # Books::RankingConfiguration. ranking_configurations is a SHARED table (music/games/
    # movies configs hold other ids), so ids are fresh and the LegacyIdMap
    # ("Books::RankingConfiguration") is the dedup key + the FK source for ranked_lists
    # (Task 4) and Phase 2c penalties. Only 4 of 47 configs are active. Per-row save! runs
    # the model validations (values sit near the numeric limits) and STI sets `type`.
    # There is NO finalize/self-ref pass: inherited_from_id is nulled for every row (owner
    # decision), so the CategoryMigrator-style parent remap is unnecessary.
    class RankingConfigurationMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::RankingConfiguration
      end

      def model_key
        "Books::RankingConfiguration"
      end

      # Active configs only (4 of 47). Stubbed in unit tests, so the archived filter is
      # exercised in the e2e run.
      def legacy_each(&block)
        legacy_model.where(archived: false).find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def upsert_row(attrs)
        Books::RankingConfiguration.transaction do
          new_id = LegacyIdMap.lookup(model: model_key, legacy_id: attrs["id"])
          rc = new_id ? Books::RankingConfiguration.find(new_id) : Books::RankingConfiguration.new
          rc.assign_attributes(RankingConfigurationTransformer.call(attrs))
          rc.save!
          LegacyIdMap.record(model: model_key, legacy_id: attrs["id"], new_id: rc.id)
        end
      end
    end
  end
end

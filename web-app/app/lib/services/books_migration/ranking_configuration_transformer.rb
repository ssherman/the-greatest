module Services
  module BooksMigration
    # Legacy `ranking_configurations` row -> Books::RankingConfiguration attributes. PURE
    # (String-keyed hash in -> symbol-keyed attrs out, no DB). Renames: inherit_list_cons
    # -> inherit_penalties, max_age_for_penalty -> max_list_dates_penalty_age,
    # max_penalty_percentage -> max_list_dates_penalty_percentage. user_id is DROPPED for
    # global configs (the model forbids a global config with a user, and every migrated
    # config is global). `type` is NOT emitted (STI sets it via .new). `inherited_from_id`
    # is NOT emitted (nulled for all — owner decision; the self-ref only matters when a
    # list is first created). archived is forced false (active-only migration). Dropped
    # legacy columns: starting_score, min_max_normalization, list_cons_are_percentages,
    # apply_global_age_penalty. Legacy created_at/updated_at preserved.
    class RankingConfigurationTransformer
      def self.call(attrs)
        {
          name: attrs["name"],
          description: attrs["description"],
          global: attrs["global"],
          user_id: attrs["global"] ? nil : attrs["user_id"],
          primary: attrs["primary"],
          archived: false,
          published_at: attrs["published_at"],
          algorithm_version: attrs["algorithm_version"],
          inherit_penalties: attrs["inherit_list_cons"],
          min_list_weight: attrs["min_list_weight"],
          max_list_dates_penalty_age: attrs["max_age_for_penalty"],
          max_list_dates_penalty_percentage: attrs["max_penalty_percentage"],
          list_limit: attrs["list_limit"],
          apply_list_dates_penalty: attrs["apply_list_dates_penalty"],
          bonus_pool_percentage: attrs["bonus_pool_percentage"],
          exponent: attrs["exponent"],
          primary_mapped_list_id: attrs["primary_mapped_list_id"],
          secondary_mapped_list_id: attrs["secondary_mapped_list_id"],
          primary_mapped_list_cutoff_limit: attrs["primary_mapped_list_cutoff_limit"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }
      end
    end
  end
end

module Services
  module BooksMigration
    # Legacy saved_searches -> Books::SavedSearch (STI on the shared saved_searches
    # table), ids preserved. Preservation is safe without a reserved ceiling because
    # the table is created empty by this increment and nothing else writes to it --
    # the books_countries case, not user_lists. It is load-bearing: /searches/:id is
    # a bookmarked URL that must keep resolving.
    #
    # Two transformations. criteria is DOUBLE-ENCODED -- the legacy jsonb column
    # holds a JSON string, because the legacy model layers `store :criteria, coder:
    # JSON` on top of jsonb -- so it is parsed before storing, and a non-Hash parse
    # raises rather than storing an unqueryable scalar. Category ids are remapped
    # through LegacyIdMap because the categories table is shared across domains and
    # its ids were NOT preserved; language and country ids are identity (verified
    # per-book across both databases) and pass through untouched.
    class SavedSearchMigrator < Migrator
      CATEGORY_ID_KEYS = %w[included_category_ids excluded_category_ids].freeze
      PASSTHROUGH_ID_KEYS = %w[
        included_language_ids excluded_language_ids
        included_country_ids excluded_country_ids
      ].freeze

      private

      def legacy_model
        LegacyBooks::SavedSearch
      end

      def model_key
        "Books::SavedSearch"
      end

      def upsert_row(attrs)
        search = ::Books::SavedSearch.find_or_initialize_by(id: attrs["id"])
        search.assign_attributes(
          user_id: attrs["user_id"],
          name: attrs["name"],
          description: attrs["description"],
          criteria: transform_criteria(attrs["criteria"]),
          public: attrs["public"] || false,
          last_executed_at: attrs["last_executed_at"],
          result_count: attrs["result_count"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        )
        search.save!
      end

      def transform_criteria(raw)
        parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
        raise "criteria did not parse to a Hash (got #{parsed.class})" unless parsed.is_a?(Hash)

        parsed.each_with_object({}) do |(key, value), out|
          out[key] = case key
          when *CATEGORY_ID_KEYS then remap_category_ids(value)
          when *PASSTHROUGH_ID_KEYS then Array(value).reject(&:blank?).map(&:to_i)
          else value
          end
        end
      end

      def remap_category_ids(value)
        Array(value).map do |legacy_id|
          category_map.fetch(legacy_id.to_i) do
            raise "no LegacyIdMap for Books::Category legacy_id=#{legacy_id} (run the categories migrator first)"
          end
        end
      end

      def category_map
        @category_map ||= LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id, :new_id).to_h
      end

      def finalize
        ::SavedSearch.connection.reset_pk_sequence!("saved_searches")
      end
    end
  end
end

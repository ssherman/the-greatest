module Services
  module BooksMigration
    # Legacy saved_searches -> Books::SavedSearch (STI on the shared saved_searches
    # table), ids preserved below the reserved ceiling
    # (Services::BooksMigration::RESERVED_CEILINGS). It is load-bearing: /searches/:id is
    # a bookmarked URL that must keep resolving.
    #
    # Two transformations. criteria is DOUBLE-ENCODED -- the legacy jsonb column
    # holds a JSON string, because the legacy model layers `store :criteria, coder:
    # JSON` on top of jsonb -- so it is parsed before storing, and a non-Hash parse
    # raises rather than storing an unqueryable scalar. Category ids are remapped
    # through LegacyIdMap because the categories table is shared across domains and
    # its ids were NOT preserved; language and country ids are identity (verified
    # per-book across both databases) and pass through untouched.
    #
    # A category deleted here is removed from the criteria and counted. In
    # data_migration:sync it also deletes legacy-origin searches that legacy no
    # longer has (spec §6).
    class SavedSearchMigrator < Migrator
      CATEGORY_ID_KEYS = %w[included_category_ids excluded_category_ids].freeze
      PASSTHROUGH_ID_KEYS = %w[
        included_language_ids excluded_language_ids
        included_country_ids excluded_country_ids
      ].freeze

      # Public: Migrator.call is `new.call`. Sets up the counters before the stream.
      def call
        @categories_removed = 0
        if sync
          @here_ids = legacy_origin_searches.pluck(:id).to_set
          @legacy_ids = Set.new
        end
        super
      end

      private

      def legacy_model
        LegacyBooks::SavedSearch
      end

      def model_key
        "Books::SavedSearch"
      end

      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("saved_searches", attrs["id"])
        @legacy_ids << attrs["id"] if sync
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

      # A mapped category deleted here since is removed from the criteria and
      # counted (spec §6). A soft-deleted one stays, because the search already
      # skips it. A legacy category with no map entry still raises: categories
      # run first, so that is a missing prerequisite.
      def remap_category_ids(value)
        Array(value).filter_map do |legacy_id|
          new_id = category_map.fetch(legacy_id.to_i) do
            raise "no LegacyIdMap for Books::Category legacy_id=#{legacy_id} (run the categories migrator first)"
          end
          next new_id if category_ids_here.include?(new_id)

          @categories_removed += 1
          nil
        end
      end

      def category_ids_here
        @category_ids_here ||= ::Books::Category.pluck(:id).to_set
      end

      def category_map
        @category_map ||= LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id, :new_id).to_h
      end

      def finalize
        delete_searches_legacy_lacks if sync
        Services::BooksMigration.bump_sequence_to_floor!("saved_searches")
      end

      # Runs only after every legacy row was written, so a failed run deletes nothing.
      def delete_searches_legacy_lacks
        @doomed_ids = (@here_ids - @legacy_ids).to_a.sort
        Services::BooksMigration.guard_deletion!("saved_searches", @doomed_ids.size, @here_ids.size)
        legacy_origin_searches.where(id: @doomed_ids).delete_all if @doomed_ids.any?
      end

      def extra_result_data
        data = {categories_removed: @categories_removed}
        return data unless sync

        data.merge(inserted: (@legacy_ids - @here_ids).size, deleted: @doomed_ids.size)
      end

      def legacy_origin_searches
        ::Books::SavedSearch.where(id: ...RESERVED_CEILINGS.fetch("saved_searches"))
      end
    end
  end
end

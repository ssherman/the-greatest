module Services
  module BooksMigration
    # Fresh-id migrator: legacy categories -> STI Books::Category. categories is a
    # SHARED table (music/games/movies categories occupy low ids), so category ids are
    # fresh and the LegacyIdMap ("Books::Category") is the dedup key + the FK source
    # for category_items and for the self-referential parent remap. The slug is
    # PRESERVED verbatim: FriendlyId would otherwise regenerate it from name on insert
    # (should_generate_new_friendly_id? is true when name_changed?), so a per-instance
    # override pins it. parent_id is remapped in finalize (both ends through the map),
    # after every category is mapped.
    class CategoryMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Category
      end

      def model_key
        "Books::Category"
      end

      def upsert_row(attrs)
        # Insert-only in sync mode: a legacy id with a map entry was seen before, so
        # a category edited or deleted here stays that way (spec §5). One mapped
        # since the last successful sync was inserted by an interrupted run that
        # never reached finalize, so its parent link is queued again.
        if sync && (mapped = LegacyIdMap.find_by(model: model_key, legacy_id: attrs["id"]))
          stash_parent_link(attrs) if inserted_by_interrupted_run?(mapped)
          return
        end

        ::Books::Category.transaction do
          new_id = LegacyIdMap.lookup(model: model_key, legacy_id: attrs["id"])
          category = new_id ? ::Books::Category.find(new_id) : ::Books::Category.new
          category.assign_attributes(CategoryTransformer.call(attrs))
          def category.should_generate_new_friendly_id? = false
          category.save!
          LegacyIdMap.record(model: model_key, legacy_id: attrs["id"], new_id: category.id)
        end
        stash_parent_link(attrs)
      end

      # Watermarks' updated_at is stamped by every successful sync (Sync#advance_watermarks).
      def inserted_by_interrupted_run?(mapped)
        @last_sync_at = LegacySyncWatermark.maximum(:updated_at) unless defined?(@last_sync_at)
        @last_sync_at.present? && mapped.created_at > @last_sync_at
      end

      def stash_parent_link(attrs)
        parent_legacy_id = attrs["parent_category_id"]
        (@parent_links ||= []) << [attrs["id"], parent_legacy_id] if parent_legacy_id
      end

      # Second pass (new DB only): resolve child + parent legacy ids through the map
      # and set parent_id. update_all bypasses FriendlyId (no slug regen) and
      # callbacks. Runs after the full pass, so every parent is already mapped.
      def finalize
        (@parent_links || []).each do |child_legacy_id, parent_legacy_id|
          child_new_id = LegacyIdMap.lookup(model: model_key, legacy_id: child_legacy_id)
          parent_new_id = LegacyIdMap.lookup(model: model_key, legacy_id: parent_legacy_id)
          next unless child_new_id && parent_new_id
          ::Books::Category.where(id: child_new_id).update_all(parent_id: parent_new_id)
        end
      end
    end
  end
end

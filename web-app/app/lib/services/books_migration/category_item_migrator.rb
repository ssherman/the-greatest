module Services
  module BooksMigration
    # Bulk join migrator: legacy book_categories -> polymorphic category_items, via
    # BulkUpsertMigrator (batched upsert_all). Preloads the migrated categories from
    # LegacyIdMap: the active (deleted: false) subset becomes the id-map, and the full
    # set of mapped legacy ids is remembered (active, soft-deleted, or since deleted here).
    # A category merged here lands its links on its merge target. A book_category
    # whose category is migrated-but-soft-deleted is dropped (the ~915 legacy corruption
    # rows); one whose category is NOT migrated at all raises (missing prerequisite:
    # categories not run, or a partial/failed run) rather than silently dropping to a
    # success-looking low count — mirrors BookMigrator#remap_language. item_id is book_id
    # directly (books preserve their id). finalize recomputes categories.item_count
    # (upsert_all bypasses the counter_cache), scoped to Books::Category.
    # A category with an applied cleanup decision carrying extra targets (a split
    # genre, or a kept one with `also:`) also gets a link to each live extra target.
    class CategoryItemMigrator < BulkUpsertMigrator
      private

      def legacy_model
        LegacyBooks::BookCategory
      end

      def model_key
        "CategoryItem"
      end

      def target_model
        CategoryItem
      end

      def unique_by
        :index_category_items_on_category_id_and_item_type_and_item_id
      end

      def preload_context
        # legacy id -> the category its links should land on: the category itself
        # when active, its merge target when merged here into a still-active
        # category. Categories deleted without a merge are absent (deliberate drop).
        @category_map = LegacyIdMap
          .where(model: "Books::Category")
          .joins("INNER JOIN categories ON categories.id = legacy_id_maps.new_id")
          .joins("LEFT JOIN categories targets ON targets.id = categories.merged_into_id")
          .where("categories.deleted = false OR (targets.id IS NOT NULL AND targets.deleted = false)")
          .pluck(:legacy_id, Arel.sql("CASE WHEN categories.deleted THEN targets.id ELSE categories.id END"))
          .to_h
        # Every mapped legacy id, including categories soft-deleted, or deleted or
        # merged here since they were mapped: dropping their items is deliberate.
        # Only an id with no map entry at all is a missing prerequisite.
        @known_category_ids = LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id).to_set
        # Genre cleanup (spec 2026-10-17 section 4): a split genre, or a kept genre
        # with `also:`, sends its links to extra categories too. Looked up for the
        # link's own category and for the category the merge redirect above lands it
        # on, so a link arriving through an alias reaches the genre's extras. Only
        # live extra targets count; one deleted or merged since is skipped.
        @new_ids = LegacyIdMap.where(model: "Books::Category").pluck(:legacy_id, :new_id).to_h
        decided = ::CategoryCleanupDecision.applied.where.not(extra_target_ids: [])
          .pluck(:category_id, :extra_target_ids)
        live_ids = ::Category.where(deleted: false, id: decided.flat_map(&:last).uniq).pluck(:id).to_set
        @extra_targets = decided.each_with_object({}) do |(category_id, ids), out|
          out[category_id] = ((out[category_id] || []) + ids.select { |id| live_ids.include?(id) }).uniq
        end
      end

      def sync_filter
        [:book_ids, "book_id"]
      end

      def build_rows(attrs)
        legacy_category_id = attrs["category_id"]
        new_category_id = @category_map[legacy_category_id]
        if new_category_id
          extras = @extra_targets.fetch(@new_ids[legacy_category_id], []) + @extra_targets.fetch(new_category_id, [])
          return ([new_category_id] + extras).uniq.map { |id| {category_id: id, item_type: "Books::Book", item_id: attrs["book_id"]} }
        end
        # No live mapping: a migrated-but-soft-deleted category is a deliberate drop
        # (legacy corruption); an unmigrated one is a missing prerequisite -> raise.
        return [] if @known_category_ids.include?(legacy_category_id)
        raise "no LegacyIdMap for Books::Category legacy_id=#{legacy_category_id} (run the categories migrator first)"
      end

      # Two legacy categories merged into one target can put the same
      # (category, book) pair twice in one batch, which upsert_all rejects.
      def flush(rows)
        rows = rows.uniq { |row| row.values_at(:category_id, :item_type, :item_id) }
        # Plain upsert_all leaves omitted columns alone on conflict, so a row the
        # ancestor reconciler wrote as inherited would stay inherited -- and be
        # deleted by a later reconcile -- even though legacy now supplies it
        # directly. Promote inherited to legacy; leave admin and legacy rows as is.
        inherited = ::CategoryItem.sources.fetch("inherited")
        legacy = ::CategoryItem.sources.fetch("legacy")
        ::CategoryItem.upsert_all(
          rows,
          unique_by: unique_by,
          record_timestamps: record_timestamps?,
          on_duplicate: Arel.sql(<<~SQL.squish)
            source = CASE WHEN category_items.source = #{inherited} THEN #{legacy} ELSE category_items.source END,
            updated_at = CASE WHEN category_items.source = #{inherited} THEN NOW() ELSE category_items.updated_at END
          SQL
        )
        @count += rows.size
      end

      def finalize
        CategoryItem.connection.execute(<<~SQL)
          UPDATE categories c
          SET item_count = (SELECT COUNT(*) FROM category_items ci WHERE ci.category_id = c.id)
          WHERE c.type = 'Books::Category'
        SQL
      end
    end
  end
end

module Services
  module BooksMigration
    # Bulk join migrator: legacy book_categories -> polymorphic category_items, via
    # BulkUpsertMigrator (batched upsert_all). The category id-map is preloaded from
    # LegacyIdMap joined to ACTIVE (deleted: false) categories only, so the ~915 legacy
    # book_categories that point at a soft-deleted category get no map hit and are
    # dropped (legacy data corruption). item_id is book_id directly (books preserve
    # their id). finalize recomputes categories.item_count (upsert_all bypasses the
    # counter_cache), scoped to Books::Category.
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
        @category_map = LegacyIdMap
          .where(model: "Books::Category")
          .joins("INNER JOIN categories ON categories.id = legacy_id_maps.new_id")
          .where(categories: {deleted: false})
          .pluck(:legacy_id, :new_id)
          .to_h
      end

      def build_rows(attrs)
        new_category_id = @category_map[attrs["category_id"]]
        return [] unless new_category_id
        [{category_id: new_category_id, item_type: "Books::Book", item_id: attrs["book_id"]}]
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

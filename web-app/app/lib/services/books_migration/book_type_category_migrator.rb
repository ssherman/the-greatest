module Services
  module BooksMigration
    # Legacy's book_type column (fiction/nonfiction/religious/poetry) has no new
    # column: the values are already category data, and saved searches resolve
    # book_type to a category at query time. This backfills the ~6,726 links that
    # are missing so that resolution retains ~100% of each type's books.
    #
    # religious maps to the "Religion & Spirituality" GENRE (legacy 47008), not the
    # near-empty "Religious" subject category, which holds 9 items against 1,899
    # typed books and would have retained 1 of 142 ranked ones.
    #
    # Legacy category ids are remapped through LegacyIdMap because the categories
    # table is shared across domains and its ids were NOT preserved.
    class BookTypeCategoryMigrator < BulkUpsertMigrator
      LEGACY_CATEGORY_IDS = {
        0 => 40348,  # Fiction
        1 => 41013,  # Nonfiction
        2 => 47008,  # Religion & Spirituality
        3 => 40876   # Poetry
      }.freeze

      private

      def legacy_model
        LegacyBooks::Book
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
        @category_ids = LEGACY_CATEGORY_IDS.transform_values do |legacy_id|
          LegacyIdMap.lookup(model: "Books::Category", legacy_id: legacy_id) ||
            raise("no LegacyIdMap for Books::Category legacy_id=#{legacy_id} (run the categories migrator first)")
        end
      end

      def build_rows(attrs)
        book_type = attrs["book_type"]
        return [] if book_type.nil?

        category_id = @category_ids[book_type]
        return [] if category_id.nil?

        [{category_id: category_id, item_type: "Books::Book", item_id: attrs["id"]}]
      end

      def finalize
        CategoryItem.connection.execute(<<~SQL)
          UPDATE categories c
          SET item_count = (SELECT COUNT(*) FROM category_items ci WHERE ci.category_id = c.id)
          WHERE c.id IN (#{@category_ids.values.join(", ")})
        SQL
      end
    end
  end
end

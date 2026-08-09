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
      # Canonical map lives in ::Books::BookType -- the query layer and the
      # saved-search summary read the same one.
      LEGACY_CATEGORY_IDS = ::Books::BookType::LEGACY_CATEGORY_IDS

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
        mapped = LegacyIdMap
          .where(model: "Books::Category", legacy_id: LEGACY_CATEGORY_IDS.values)
          .joins("INNER JOIN categories ON categories.id = legacy_id_maps.new_id")
          .pluck(:legacy_id, :new_id, "categories.deleted")
          .to_h { |legacy_id, new_id, deleted| [legacy_id, [new_id, deleted]] }

        @category_ids = LEGACY_CATEGORY_IDS.transform_values do |legacy_id|
          new_id, deleted = mapped[legacy_id] ||
            raise("no LegacyIdMap for Books::Category legacy_id=#{legacy_id} (run the categories migrator first)")
          raise "target category (id=#{new_id}) for Books::Category legacy_id=#{legacy_id} is soft-deleted" if deleted
          new_id
        end
      end

      def legacy_each(&block)
        legacy_model.select(:id, :book_type)
          .find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
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

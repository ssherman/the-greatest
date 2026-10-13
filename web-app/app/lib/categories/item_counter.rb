# frozen_string_literal: true

module Categories
  # Recomputes the item_count counter cache for specific categories. Bulk SQL
  # writers (Merger, AncestorReconciler) bypass CategoryItem's counter_cache,
  # so they call this once at the end instead.
  class ItemCounter
    def self.call(category_ids)
      ids = Array(category_ids).map(&:to_i).uniq
      return 0 if ids.empty?

      ::Category.connection.update(<<~SQL)
        UPDATE categories c
        SET item_count = (SELECT COUNT(*) FROM category_items ci WHERE ci.category_id = c.id)
        WHERE c.id IN (#{ids.join(",")})
      SQL
    end
  end
end

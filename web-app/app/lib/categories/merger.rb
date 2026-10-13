# frozen_string_literal: true

module Categories
  # Merges one category into another (spec §1.3). Bulk SQL, because cleanup
  # merges categories with tens of thousands of links: the old row-by-row copy
  # fired a counter-cache update and a reindex request per link.
  #
  # The source ends soft-deleted with merged_into pointing at the target, and
  # anything previously merged into the source is repointed too, so a lookup
  # never follows a chain. Readers (URLs, saved searches, the sync) resolve a
  # merged category through Category#canonical / Category.replace_merged_ids.
  class Merger
    attr_reader :category, :category_to_merge_with

    def initialize(category:, category_to_merge_with:)
      @category = category
      @category_to_merge_with = category_to_merge_with
    end

    def merge
      refuse_invalid!
      moved = []

      ::Category.transaction do
        moved = move_items
        ::Category.where(merged_into_id: source.id).update_all(merged_into_id: target.id)
        ::Category.where(parent_id: source.id).update_all(parent_id: target.id)
        update_alternative_names
        # update! (not update_column) so Category's reindex callback still fires.
        source.update!(deleted: true, merged_into: target)
        ItemCounter.call([source.id, target.id])
      end

      ItemReindexer.queue_items(moved)
      reconcile(moved) if source.location? || target.location?
      target
    end

    private

    def source = @category

    def target = @category_to_merge_with

    def refuse_invalid!
      raise Refused, "A category can't be merged into itself." if source.id == target.id
      raise Refused, "Categories from different sites can't be merged." if source.type != target.type
      raise Refused, "Deleted categories can't be merged." if source.deleted? || target.deleted?

      raise Refused, "Merged categories can't be merge targets." if target.merged_into_id.present?
      raise Refused, "A category can't be merged into a place inside it." if descendant?(target)

      return unless source.is_a?(::Books::Category)

      protected_ids = ::Books::Category.protected_ids
      if protected_ids.include?(source.id) || protected_ids.include?(target.id)
        raise Refused, "Fiction, Nonfiction, Poetry and Religion & Spirituality can't be merged."
      end
      if source.child_categories.where(deleted: false).exists? && !target.location?
        raise Refused, "#{source.name} has places under it, so it can only merge into a location."
      end
    end

    # True when node sits below source. Generic (not Books::Category#ancestors)
    # because children move for every site; capped so a cycle can't loop.
    def descendant?(node)
      parent = node.parent
      ::Books::Category::MAX_DEPTH.times do
        return false if parent.nil?
        return true if parent.id == source.id

        parent = parent.parent
      end
      false
    end

    # Copies every link to the target. On a conflict a direct source beats an
    # inherited one; otherwise the target's row is left as it is.
    def move_items
      inherited = ::CategoryItem.sources.fetch("inherited").to_i
      pairs = source.category_items.pluck(:item_type, :item_id)

      ::CategoryItem.connection.execute(<<~SQL)
        INSERT INTO category_items (category_id, item_type, item_id, source, created_at, updated_at)
        SELECT #{target.id.to_i}, item_type, item_id, source, NOW(), NOW()
        FROM category_items
        WHERE category_id = #{source.id.to_i}
        ON CONFLICT (category_id, item_type, item_id) DO UPDATE
          SET source = EXCLUDED.source, updated_at = NOW()
          WHERE category_items.source = #{inherited} AND EXCLUDED.source <> #{inherited}
      SQL
      ::CategoryItem.where(category_id: source.id).delete_all
      pairs
    end

    def update_alternative_names
      names = target.alternative_names + [source.name] + source.alternative_names
      target.alternative_names = names.uniq - [target.name]
      target.save!
    end

    def reconcile(pairs)
      book_ids = pairs.filter_map { |type, id| id if type == "Books::Book" }
      AncestorReconciler.call(item_ids: book_ids) if book_ids.any?
    end
  end
end

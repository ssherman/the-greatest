# frozen_string_literal: true

module Categories
  class Deleter
    attr_reader :category, :soft

    def initialize(category:, soft: true)
      @category = category
      @soft = soft
    end

    def delete
      refuse_protected!
      if @soft
        soft_delete
      else
        hard_delete
      end
    end

    private

    def refuse_protected!
      return unless @category.is_a?(::Books::Category)
      return unless ::Books::Category.protected_ids.include?(@category.id)

      raise Refused, "Fiction, Nonfiction, Poetry and Religion & Spirituality can't be deleted."
    end

    def soft_delete
      book_ids = @category.category_items.where(item_type: "Books::Book").pluck(:item_id)
      Category.transaction do
        # update! rather than update_column: update_column fires no callbacks, which
        # would silently skip Category#queue_items_for_reindexing and reintroduce the
        # stale-index defect this service is meant to be safe for.
        @category.update!(deleted: true)
        @category.category_items.destroy_all
      end
      # A deleted location no longer justifies the inherited links above it.
      AncestorReconciler.call(item_ids: book_ids) if @category.location? && book_ids.any?
    end

    def hard_delete
      @category.destroy
    end
  end
end

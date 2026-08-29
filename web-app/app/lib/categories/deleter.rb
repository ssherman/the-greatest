# frozen_string_literal: true

module Categories
  class Deleter
    attr_reader :category, :soft

    def initialize(category:, soft: true)
      @category = category
      @soft = soft
    end

    def delete
      if @soft
        soft_delete
      else
        hard_delete
      end
    end

    private

    def soft_delete
      Category.transaction do
        # update! rather than update_column: update_column fires no callbacks, which
        # would silently skip Category#queue_items_for_reindexing and reintroduce the
        # stale-index defect this service is meant to be safe for.
        @category.update!(deleted: true)
        @category.category_items.destroy_all
      end
    end

    def hard_delete
      @category.destroy
    end
  end
end

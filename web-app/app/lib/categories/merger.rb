# frozen_string_literal: true

module Categories
  class Merger
    attr_reader :category, :category_to_merge_with

    def initialize(category:, category_to_merge_with:)
      @category = category
      @category_to_merge_with = category_to_merge_with
    end

    def merge
      Category.transaction do
        merge_category_items
        update_alternative_names
        soft_delete_source_category
      end

      @category_to_merge_with
    end

    private

    def merge_category_items
      @category.category_items.find_each do |category_item|
        # Find or create the association in the target category
        @category_to_merge_with.category_items.find_or_create_by!(
          item: category_item.item
        )
      end
    end

    def update_alternative_names
      @category_to_merge_with.alternative_names += Array.wrap(@category.name)
      @category_to_merge_with.alternative_names.uniq!
      @category_to_merge_with.save!
    end

    def soft_delete_source_category
      Deleter.new(category: @category, soft: true).delete
    end
  end
end

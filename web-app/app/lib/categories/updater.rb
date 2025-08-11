# frozen_string_literal: true

module Categories
  class Updater
    attr_reader :category, :attributes

    def initialize(category:, attributes:)
      @category = category
      @attributes = attributes
      @category.attributes = @attributes
    end

    def update
      if category.name_changed?
        handle_name_change
      else
        simple_update
      end
    end

    private

    def handle_name_change
      existing = find_existing_category_with_same_name

      Category.transaction do
        if existing.nil?
          create_renamed_category
        else
          merge_with_existing_category(existing)
        end
      end
    end

    def simple_update
      @category.save!
      @category
    end

    def find_existing_category_with_same_name
      Category.where(type: @category.type)
        .where("LOWER(name) = LOWER(?)", @category.name)
        .where.not(id: @category.id)
        .first
    end

    def create_renamed_category
      old_name = @category.name_was

      # Create new category with updated name and old name in alternative_names
      renamed_category = @category.class.create!(
        name: @category.name,
        alternative_names: Array.wrap(old_name),
        category_type: @category.category_type,
        import_source: @category.import_source,
        description: @category.description,
        parent: @category.parent
      )

      # Transfer all category items to the new category
      transfer_category_items_to(renamed_category)

      # Soft delete the old category
      Deleter.new(category: @category, soft: true).delete

      # Reset attributes on original category to avoid confusion
      @category.restore_attributes

      renamed_category
    end

    def merge_with_existing_category(existing)
      # Reset attributes on original category
      @category.restore_attributes

      # Restore existing category if it was soft deleted
      existing.update!(deleted: false) if existing.deleted?

      # Merge the categories
      Merger.new(category: @category, category_to_merge_with: existing).merge

      existing
    end

    def transfer_category_items_to(target_category)
      @category.category_items.find_each do |category_item|
        target_category.category_items.find_or_create_by!(item: category_item.item)
      end
    end
  end
end

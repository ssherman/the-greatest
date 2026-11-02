# frozen_string_literal: true

module Categories
  # Tags an item with a category, or removes the tag. The one place the rules
  # live, shared by the admin UI and the API: a category must belong to the
  # item's site and be live; tagging twice is a success; an `inherited` row
  # (an ancestor location AncestorReconciler materialised) cannot be removed
  # directly, only by removing the more specific location it comes from.
  class ItemLinker
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    class << self
      def link(item:, category:)
        refusal = refusal_for(item, category)
        return failure(refusal) if refusal

        existing = item.category_items.find_by(category_id: category.id)
        if existing&.source_inherited?
          existing.update!(source: :admin)
        elsif existing.nil?
          item.category_items.create!(category: category, source: :admin)
        end

        reconcile(item)
        success(item)
      rescue ActiveRecord::RecordNotUnique
        # A concurrent tag of the same category won the race: the end state is what was asked for.
        reconcile(item)
        success(item)
      end

      def unlink(item:, category:)
        row = item.category_items.find_by(category_id: category.id)
        return failure("That item doesn't have that category.") if row.nil?

        if row.source_inherited?
          names = inherited_from(item: item, category: category).map(&:name).join(", ")
          return failure("#{category.name} comes from #{names}; remove that instead.")
        end

        row.destroy!
        reconcile(item)
        success(item)
      end

      # The direct location links behind an inherited row.
      def inherited_from(item:, category:)
        inherited_map(item: item)[category.id] || []
      end

      # {ancestor category id => [direct locations beneath it]} for the item,
      # computed once so a page of rows does not query per row.
      def inherited_map(item:)
        return {} unless item.is_a?(::Books::Book)

        direct = item.category_items.direct.includes(:category).map(&:category)
        direct.select { |c| c.is_a?(::Books::Category) && c.location? }.each_with_object({}) do |location, map|
          location.ancestors.each { |ancestor| (map[ancestor.id] ||= []) << location }
        end
      end

      private

      def refusal_for(item, category)
        item_domain = ::Admin::DomainRouting.domain_for(item)&.to_s
        category_domain = category.class.module_parent_name&.downcase
        return "That category belongs to a different section." unless item_domain.present? && item_domain == category_domain

        return unless category.deleted?

        canonical = category.canonical
        if category.merged_into_id.present? && canonical
          "That category was merged into #{canonical.name} (#{canonical.id})."
        else
          "That category has been deleted."
        end
      end

      def reconcile(item)
        ::Categories::AncestorReconciler.call(item_ids: [item.id]) if item.is_a?(::Books::Book)
      end

      def success(item)
        Result.new(success?: true, data: item.category_items.includes(:category).order("categories.name"), errors: [])
      end

      def failure(message)
        Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
